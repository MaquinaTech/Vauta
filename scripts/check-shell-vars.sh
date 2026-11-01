#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
#
# Fails when a shell variable is followed straight by a byte that is not ASCII (an ellipsis right after "$latest", say):
# macOS's bash 3.2 reads that byte as part of the name, and under `set -u` the script stops on an unbound variable (the
# update.sh of 0.9.3). Write the name in braces, "${latest}", before such a character. Checks the files given, else every
# shell script Git tracks.
#
#   scripts/check-shell-vars.sh [file ...]
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -gt 0 ]]; then
  files=("$@")
else
  files=()
  while IFS= read -r f; do files+=("$f"); done < <(git ls-files '*.sh')
fi
if [[ ${#files[@]} -eq 0 ]]; then
  echo "ERROR: no shell scripts to check (is this a Git checkout?)." >&2
  exit 2
fi
if LC_ALL=C grep -nHE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~[:space:]]' "${files[@]}"; then
  echo "ERROR: a variable is followed by a non-ASCII character (above). Write it as \${name} before the character." >&2
  exit 1
fi
echo "OK: no variable is followed by a non-ASCII character in ${#files[@]} shell scripts."
