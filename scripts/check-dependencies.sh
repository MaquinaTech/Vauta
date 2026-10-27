#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
#
# Vauta has exactly one third-party package: the pinned MaquinaTech fork of mlx-swift (with its own dependency, swift-numerics).
# This fails on any other pin, on a different revision of those two, and on a Package.swift that pins by version or branch.
#
#   scripts/check-dependencies.sh
set -euo pipefail
cd "$(dirname "$0")/.."

FORK_URL="https://github.com/MaquinaTech/mlx-swift.git"
FORK_REVISION="999f159e905affa3cc25bc1127a6cb489a5ffbb9"
NUMERICS_URL="https://github.com/apple/swift-numerics"
NUMERICS_REVISION="0c0290ff6b24942dadb83a929ffaaa1481df04a2"

fail() { echo "ERROR: $1" >&2; exit 1; }

[[ -f Package.resolved ]] || fail "Package.resolved is missing; it is committed so the pins are reviewed."

# Package.swift: one remote package, by revision.
declared="$(grep -c '\.package(' Package.swift || true)"
[[ "$declared" == "1" ]] || fail "Package.swift declares $declared packages; Vauta allows exactly one (the pinned mlx-swift fork)."
grep -q "\.package(url: \"$FORK_URL\", revision: \"$FORK_REVISION\")" Package.swift \
  || fail "Package.swift must pin $FORK_URL by revision $FORK_REVISION."

# Package.resolved: exactly the fork and swift-numerics, at those revisions.
python3 - "$FORK_URL" "$FORK_REVISION" "$NUMERICS_URL" "$NUMERICS_REVISION" <<'PY'
import json, sys
fork_url, fork_rev, num_url, num_rev = sys.argv[1:5]
pins = json.load(open("Package.resolved"))["pins"]
found = {p["location"]: p["state"].get("revision") for p in pins}
want = {fork_url: fork_rev, num_url: num_rev}
if found != want:
    print("ERROR: Package.resolved has the pins", found, "but only", want, "are allowed.", file=sys.stderr)
    sys.exit(1)
PY
# The fork changes .gitmodules so that Source/Cmlx/mlx comes from MaquinaTech/mlx. Its commit is fixed inside the pinned fork commit
# (a gitlink), but nothing else records it: assert it here so a moved or removed tag is noticed, and keep the vauta-0.9.0 tags protected.
MLX_CORE_REVISION="d1dfda2ff2f902a4f24fedf6899aa15ee45b8d3c"
# The C bindings (Source/Cmlx/mlx-c) are the upstream submodule, unchanged by the fork.
MLX_C_REVISION="ebc88f10caa1b625e6b581437a8dea6df8a70085"
CHECKOUT=".build/checkouts/mlx-swift"
if [[ -d "$CHECKOUT" ]]; then
  linked="$(git -C "$CHECKOUT" ls-tree HEAD Source/Cmlx/mlx 2>/dev/null | awk '{print $3}')"
  [[ "$linked" == "$MLX_CORE_REVISION" ]] \
    || fail "The mlx-swift fork links Source/Cmlx/mlx at '$linked'; expected $MLX_CORE_REVISION (MaquinaTech/mlx)."
  linkedC="$(git -C "$CHECKOUT" ls-tree HEAD Source/Cmlx/mlx-c 2>/dev/null | awk '{print $3}')"
  [[ "$linkedC" == "$MLX_C_REVISION" ]] \
    || fail "The mlx-swift fork links Source/Cmlx/mlx-c at '$linkedC'; expected $MLX_C_REVISION (ml-explore/mlx-c)."
fi
echo "Dependencies: the pinned mlx-swift fork and swift-numerics only."
