#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
#
# Lists source files whose first lines lack the license header:
#   // SPDX-License-Identifier: Apache-2.0        (or "# …" in shell scripts)
#   // SPDX-FileCopyrightText: <year> <holder>
# Checks Swift files (Package.swift, Sources, Tests, tools) and scripts/*.sh.
#
#   scripts/check-headers.sh          exit 1 if any file lacks the header
#   scripts/check-headers.sh --warn   only report (exit 0)
set -euo pipefail
cd "$(dirname "$0")/.."

WARN=0
case "${1:-}" in
  --warn) WARN=1 ;;
  "") ;;
  *) echo "usage: $0 [--warn]" >&2; exit 2 ;;
esac

MISSING=()
TOTAL=0
while IFS= read -r -d '' file; do
  TOTAL=$((TOTAL + 1))
  # The header must be near the top (Package.swift starts with its tools-version line).
  HEAD="$(head -n 6 "$file")"
  if [[ "$HEAD" != *"SPDX-License-Identifier: Apache-2.0"* || "$HEAD" != *"SPDX-FileCopyrightText: "* ]]; then
    MISSING+=("$file")
  fi
done < <(
  {
    [[ -f Package.swift ]] && printf '%s\0' Package.swift
    find Sources Tests tools -type f -name '*.swift' -print0 2>/dev/null
    find scripts -type f -name '*.sh' -print0 2>/dev/null
  } | sort -z
)

if [[ ${#MISSING[@]} -eq 0 ]]; then
  echo "OK: all $TOTAL source files have the SPDX header."
  exit 0
fi
printf 'Missing SPDX header: %s\n' "${MISSING[@]}"
echo "${#MISSING[@]} of $TOTAL source files lack the SPDX header."
[[ $WARN -eq 1 ]] && exit 0
exit 1
