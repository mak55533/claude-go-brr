#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

usage() {
  echo "usage: submit.sh <task prompt>" >&2
  exit "${1:-64}"
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage 0
[[ $# -gt 0 ]] || usage 64

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

CONFIG="${OFFLOAD_CONFIG:-$HOME/.config/offload/config}"
# shellcheck disable=SC1090
[[ -f "$CONFIG" ]] && source "$CONFIG"
if [[ -z "${OFFLOAD_API_KEY:-}" ]]; then
  echo "error: OFFLOAD_API_KEY not set" >&2
  echo "Run /claude-go-brr:setup, open the printed GitHub URL, then run /claude-go-brr:setup DEVICE_CODE after GitHub completes." >&2
  exit 78
fi

exec "$CLIENT" submit "$@"
