#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
#
# What building Vauta needs, checked before install.sh and update.sh start a build that would fail minutes later: a Mac with
# Apple silicon, macOS 26 or later, the Command Line Tools with the macOS 27 SDK and Swift 6.4, and about 8 GB free on the disk of
# this folder. Each missing piece stops with what to do. It also sets VAUTA_JOBS (how many files swift builds at once) from the
# Mac's memory when it is not set, so a Mac with 16 GB or less does not run out of memory compiling MLX.
#
#   source scripts/preflight.sh && vauta_preflight     from install.sh and update.sh (exports VAUTA_JOBS)
#   scripts/preflight.sh                               on its own: prints what it found
#   VAUTA_SKIP_PREFLIGHT=1                             skips the checks (VAUTA_JOBS is still set)

vauta_preflight_fail() { echo "ERROR: $*" >&2; return 1; }

vauta_preflight() {
  local min_free_gb=8
  if [[ "${VAUTA_SKIP_PREFLIGHT:-0}" != 1 ]]; then
    local arch; arch="$(uname -m)"
    [[ "$arch" == arm64 ]] || { vauta_preflight_fail "Vauta needs a Mac with Apple silicon (arm64); this one is $arch."; return 1; }

    local macos; macos="$(sw_vers -productVersion 2>/dev/null || true)"
    [[ "${macos%%.*}" =~ ^[0-9]+$ && "${macos%%.*}" -ge 26 ]] || {
      vauta_preflight_fail "Vauta needs macOS 26 or later; this Mac has ${macos:-an unknown version}. Update it in System Settings → General → Software Update."
      return 1
    }

    xcode-select -p >/dev/null 2>&1 || {
      vauta_preflight_fail "The Command Line Tools are missing. Run: xcode-select --install, then run this again."
      return 1
    }

    local sdk; sdk="$(xcrun --show-sdk-version 2>/dev/null || true)"
    [[ "${sdk%%.*}" =~ ^[0-9]+$ && "${sdk%%.*}" -ge 27 ]] || {
      vauta_preflight_fail "Vauta builds with the macOS 27 SDK (Command Line Tools for Xcode 27 or later); this Mac has ${sdk:-none}. Update the Command Line Tools in System Settings → General → Software Update."
      return 1
    }

    local swift_version; swift_version="$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)"
    local major="${swift_version%%.*}" minor="${swift_version#*.}"
    if ! [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || (( major < 6 || (major == 6 && minor < 4) )); then
      vauta_preflight_fail "Vauta needs Swift 6.4 or later; this Mac has ${swift_version:-none}. Update the Command Line Tools in System Settings → General → Software Update."
      return 1
    fi

    local free_kb; free_kb="$(df -k . 2>/dev/null | awk 'NR == 2 { print $4 }')"
    if [[ "$free_kb" =~ ^[0-9]+$ ]] && (( free_kb < min_free_gb * 1024 * 1024 )); then
      vauta_preflight_fail "Building Vauta needs about $min_free_gb GB free on this disk; there are $(( free_kb / 1024 / 1024 )) GB. Free some space and run this again."
      return 1
    fi
  fi

  # Each Swift job of MLX's C++ can take a few GB: fewer at once on a Mac with little memory.
  if [[ -z "${VAUTA_JOBS:-}" ]]; then
    local memory; memory="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
    # 8 GB: 2 at once; up to 24 GB: 3 (AGENTS.md's -j 3); more memory: Swift's default, one per core.
    if [[ "$memory" =~ ^[0-9]+$ ]] && (( memory > 0 && memory <= 9 * 1024 * 1024 * 1024 )); then
      VAUTA_JOBS=2
    elif [[ "$memory" =~ ^[0-9]+$ ]] && (( memory > 0 && memory <= 25 * 1024 * 1024 * 1024 )); then
      VAUTA_JOBS=3
    fi
  fi
  [[ -z "${VAUTA_JOBS:-}" ]] || export VAUTA_JOBS
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -uo pipefail
  cd "$(dirname "$0")/.." || exit 1
  vauta_preflight || exit 1
  echo "Ready to build Vauta${VAUTA_JOBS:+ (VAUTA_JOBS=$VAUTA_JOBS)}."
fi
