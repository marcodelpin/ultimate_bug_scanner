#!/usr/bin/env bash
# Backward-compatible wrapper for the legacy JS/TS scanner.
# The implementation now lives in modules/ubs-js.sh so the new meta-runner
# (ubs) can share the same module.

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
MODULE_PATH="${SCRIPT_DIR}/modules/ubs-js.sh"

if [[ ! -x "$MODULE_PATH" ]]; then
  echo "Error: JS scanner module not found at ${MODULE_PATH}" >&2
  exit 1
fi

exec "$MODULE_PATH" "$@"

