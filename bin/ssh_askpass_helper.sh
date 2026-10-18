#!/usr/bin/env bash
if [[ "${1:-}" == *"(yes/no"* ]]; then
  printf 'yes\n'
else
  printf '%s\n' "${SSHPASS_VALUE:-}"
fi

