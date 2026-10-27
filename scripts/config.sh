#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
#
# Build settings shared by build-app.sh, install.sh and package.sh.
# Each machine can override them in scripts/local.env (never committed or packaged), e.g.:
#   VAUTA_BUNDLE_ID=com.yourname.vauta
#   VAUTA_SWIFT_FLAGS="-Xswiftc -DSOME_FLAG"
# The bundle ID is Vauta's identity for macOS: permissions, Keychain items, the sandbox
# container and the speech model reservation. Do not change it after installing, or Vauta
# starts from scratch (the old data stays in the old container).
if [[ -f scripts/local.env ]]; then
  # shellcheck disable=SC1091
  source scripts/local.env
fi
# shellcheck disable=SC1091
source scripts/legacy-env.sh
VAUTA_BUNDLE_ID="${VAUTA_BUNDLE_ID:-local.vauta.app}"
VAUTA_SWIFT_FLAGS="${VAUTA_SWIFT_FLAGS:-}"
if [[ ! "$VAUTA_BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  echo "ERROR: invalid VAUTA_BUNDLE_ID: $VAUTA_BUNDLE_ID (example: com.yourname.vauta)" >&2
  exit 1
fi
# shellcheck disable=SC2034  # used by the scripts that source this file
read -r -a VAUTA_SWIFT_FLAG_ARRAY <<< "$VAUTA_SWIFT_FLAGS"
