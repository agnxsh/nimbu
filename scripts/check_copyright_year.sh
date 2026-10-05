#!/usr/bin/env bash
# nimbu
# Copyright (c) 2026 Agnish Ghosh
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Files added or modified relative to BASE (default: HEAD^, or all tracked
# files when there is no parent commit) must carry the current year in their
# copyright header - see notes/0006-coding-standards.md §1

set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

HOLDER="Agnish Ghosh"
BASE="${1:-HEAD^}"
current_year="$(date +"%Y")"

# Same exclusions as nimbus-eth2's CI lint job, plus our notes
excluded_files="LICENSE-MIT|LICENSE-APACHEv2|\.gitmodules|\.editorconfig|\.gitignore"
excluded_extensions="ans|bin|yml|yaml|json|md|png|ssz|txt|lock"

if git rev-parse -q --verify "${BASE}^{commit}" >/dev/null; then
  changed() { git diff --name-only --diff-filter=AM --ignore-submodules "${BASE}"; }
else
  changed() { git ls-files --cached --others --exclude-standard; }
fi

problematic_files=()
while read -r file; do
  if ! grep -qE "Copyright \(c\) .*${current_year} ${HOLDER}" "${file}"; then
    problematic_files+=("${file}")
  fi
done < <(changed | grep -vE '^vendor/' | grep -vE "(\.(${excluded_extensions})|(^|/)(${excluded_files}))$" || true)

if (( ${#problematic_files[@]} )); then
  echo "The following files do not have an up-to-date copyright year (${current_year} ${HOLDER}):"
  for file in "${problematic_files[@]}"; do
    echo "- ${file}"
  done
  exit 2
fi
