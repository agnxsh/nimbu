#!/usr/bin/env bash
# nimbu
# Copyright (c) 2026 Agnish Ghosh
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Every Nim module must track exceptions - see notes/0006-coding-standards.md §1
# Adapted from vendor/nimbus-eth2/scripts/check_exception_headers.sh, but
# checks all tracked files rather than only those changed in the last commit.

set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

problematic_files=()
while read -r file; do
  if ! grep -qE '^{\.push raises: \[\](, gcsafe)?\.}$' "${file}"; then
    problematic_files+=("${file}")
  fi
done < <(git ls-files --cached --others --exclude-standard -- '*.nim' ':!:vendor/**')

if (( ${#problematic_files[@]} )); then
  echo "The following files do not have '{.push raises: [], gcsafe.}' (gcsafe optional):"
  for file in "${problematic_files[@]}"; do
    echo "- ${file}"
  done
  echo "See https://status-im.github.io/nim-style-guide/errors.exceptions.html"
  exit 2
fi
