#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

if [[ -n "${OFFLOAD_BIN:-}" ]]; then
  CLIENT="$OFFLOAD_BIN"
else
  BUNDLED_CLIENT="$SCRIPT_DIR/../offload.sh"
  REPO_CLIENT="$(cd "$SCRIPT_DIR/../../../.." && pwd -P)/offload.sh"
  if [[ -x "$BUNDLED_CLIENT" ]]; then
    CLIENT="$BUNDLED_CLIENT"
  elif [[ -x "$REPO_CLIENT" ]]; then
    CLIENT="$REPO_CLIENT"
  elif command -v offload >/dev/null 2>&1; then
    CLIENT="$(command -v offload)"
  else
    echo "error: could not find offload client; set OFFLOAD_BIN or install offload on PATH" >&2
    exit 78
  fi
fi

exec "$CLIENT" env "$@"
