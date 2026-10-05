#!/usr/bin/env bash
# nimbu
# Copyright (c) 2026 Agnish Ghosh
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Keep top-level `vendor/*` submodules pinned to exactly the commits that the
# pinned `vendor/nimbus-eth2` uses - see notes/0004-repo-layout-and-vendoring.md
#
# Usage:
#   scripts/sync_vendor.sh          add missing submodules, pin all to eth2's commits
#   scripts/sync_vendor.sh --check  exit 2 if any pin differs (CI)

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

ETH2="vendor/nimbus-eth2"

# eth2 submodules we do not mirror at top level:
# - network/devnet configs are incbin'ed relative to eth2's own sources and are
#   initialised inside `vendor/nimbus-eth2` instead (see Makefile)
# - test vectors and benchmarks are not needed
SKIP_RE='^vendor/(mainnet|sepolia|hoodi|gnosis-chain-configs|glamsterdam-devnets|nim-eth2-scenarios|nimbus-benchmarking)$'

CHECK=0
if [[ "${1:-}" == "--check" ]]; then
  CHECK=1
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--check]" >&2
  exit 1
fi

if [[ ! -f "${ETH2}/.gitmodules" ]]; then
  echo "'${ETH2}' is not checked out; run 'git submodule update --init ${ETH2}' first" >&2
  exit 1
fi

mismatches=0
while read -r key path; do
  [[ "${path}" =~ ${SKIP_RE} ]] && continue

  name="${key#submodule.}"
  name="${name%.path}"
  url="$(git config -f "${ETH2}/.gitmodules" --get "submodule.${name}.url")"
  branch="$(git config -f "${ETH2}/.gitmodules" --get "submodule.${name}.branch" || true)"
  expected="$(git -C "${ETH2}" ls-tree HEAD "${path}" | awk '{ print $3 }')"

  if [[ -z "${expected}" ]]; then
    echo "${path}: not pinned in ${ETH2}" >&2
    exit 2
  fi

  # Commit recorded in our index (works even when the submodule is not checked out)
  actual="$(git ls-files --stage -- "${path}" | awk '$1 == "160000" { print $2 }')"

  if (( CHECK )); then
    if [[ "${actual}" != "${expected}" ]]; then
      echo "${path}: pinned at '${actual:-<missing>}', nimbus-eth2 uses '${expected}'"
      mismatches=$((mismatches + 1))
    fi
    continue
  fi

  if [[ -z "${actual}" ]]; then
    echo "Adding ${path} (${url}${branch:+, branch ${branch}})"
    if [[ -n "${branch}" ]]; then
      git submodule add -q -b "${branch}" "${url}" "${path}"
    else
      git submodule add -q "${url}" "${path}"
    fi
  elif [[ ! -e "${path}/.git" ]]; then
    git submodule update -q --init "${path}"
  fi

  if [[ "$(git -C "${path}" rev-parse HEAD)" != "${expected}" ]]; then
    if ! git -C "${path}" cat-file -e "${expected}^{commit}" 2>/dev/null; then
      git -C "${path}" fetch -q origin "${expected}" || git -C "${path}" fetch -q origin
    fi
    git -C "${path}" checkout -q "${expected}"
    echo "Pinned ${path} at ${expected}"
  fi
  git add "${path}"
done < <(git config -f "${ETH2}/.gitmodules" --get-regexp '^submodule\..*\.path$')

if (( CHECK )) && (( mismatches )); then
  echo "${mismatches} submodule(s) out of sync with ${ETH2}; run scripts/sync_vendor.sh"
  exit 2
fi

# Also add nested submodules of the libraries themselves (e.g. nim-kzg4844's C sources)
if (( ! CHECK )); then
  git submodule update -q --init --recursive -- $(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' | awk '$2 != "vendor/nimbus-eth2" { print $2 }')
fi
