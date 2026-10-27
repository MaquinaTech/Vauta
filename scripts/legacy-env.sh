#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
#
# Sourced by the scripts that read VAUTA_* variables. An earlier version used ACTA_* names:
# the old ACTA_* names still work (deprecated) when the matching VAUTA_* name is not set.
for _old in $(compgen -v ACTA_); do
  _new="VAUTA_${_old#ACTA_}"
  if [[ -z "${!_new:-}" ]]; then
    printf -v "$_new" '%s' "${!_old}"
    export "${_new?}"
    echo "NOTE: $_old is deprecated, use $_new." >&2
  fi
done
unset _old _new
