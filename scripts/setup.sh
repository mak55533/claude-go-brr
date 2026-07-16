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

CONFIG="${OFFLOAD_CONFIG:-$HOME/.config/offload/config}"
ENV_OFFLOAD_API_URL="${OFFLOAD_API_URL-}"
ENV_OFFLOAD_API_KEY="${OFFLOAD_API_KEY-}"
ENV_OFFLOAD_REMOTE="${OFFLOAD_REMOTE-}"
ENV_OFFLOAD_GITHUB_LOGIN="${OFFLOAD_GITHUB_LOGIN-}"
# shellcheck disable=SC1090
[[ -f "$CONFIG" ]] && source "$CONFIG"
CONFIG_OFFLOAD_API_KEY="${OFFLOAD_API_KEY-}"
CONFIG_OFFLOAD_GITHUB_LOGIN="${OFFLOAD_GITHUB_LOGIN-}"
[[ -n "$ENV_OFFLOAD_API_URL" ]] && OFFLOAD_API_URL="$ENV_OFFLOAD_API_URL"
[[ -n "$ENV_OFFLOAD_API_KEY" ]] && OFFLOAD_API_KEY="$ENV_OFFLOAD_API_KEY"
[[ -n "$ENV_OFFLOAD_REMOTE" ]] && OFFLOAD_REMOTE="$ENV_OFFLOAD_REMOTE"
[[ -n "$ENV_OFFLOAD_GITHUB_LOGIN" ]] && OFFLOAD_GITHUB_LOGIN="$ENV_OFFLOAD_GITHUB_LOGIN"
NAME="${OFFLOAD_CLIENT_NAME:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo my-laptop)}"

require_matching_saved_login() {
  [[ -n "${ENV_OFFLOAD_GITHUB_LOGIN:-}" ]] || return 0
  [[ -z "${ENV_OFFLOAD_API_KEY:-}" ]] || return 0
  [[ -n "${CONFIG_OFFLOAD_API_KEY:-}" ]] || return 0
  [[ -n "${CONFIG_OFFLOAD_GITHUB_LOGIN:-}" ]] || return 0

  local requested_lc saved_lc
  requested_lc="$(printf '%s' "$ENV_OFFLOAD_GITHUB_LOGIN" | tr '[:upper:]' '[:lower:]')"
  saved_lc="$(printf '%s' "$CONFIG_OFFLOAD_GITHUB_LOGIN" | tr '[:upper:]' '[:lower:]')"
  [[ "$requested_lc" == "$saved_lc" ]] && return 0

  {
    echo "error: already authenticated as $CONFIG_OFFLOAD_GITHUB_LOGIN, but OFFLOAD_GITHUB_LOGIN=$ENV_OFFLOAD_GITHUB_LOGIN was requested"
    echo
    echo "Log out of the previous offload account before using a different GitHub account."
    echo "Run:"
    echo "/claude-go-brr:setup logout"
    echo
    echo "Then run:"
    echo "/claude-go-brr:setup login"
  } >&2
  exit 78
}

reload_saved_config() {
  # shellcheck disable=SC1090
  [[ -f "$CONFIG" ]] && source "$CONFIG"
  CONFIG_OFFLOAD_API_KEY="${OFFLOAD_API_KEY-}"
  CONFIG_OFFLOAD_GITHUB_LOGIN="${OFFLOAD_GITHUB_LOGIN-}"
  [[ -n "$ENV_OFFLOAD_API_URL" ]] && OFFLOAD_API_URL="$ENV_OFFLOAD_API_URL"
  [[ -n "$ENV_OFFLOAD_API_KEY" ]] && OFFLOAD_API_KEY="$ENV_OFFLOAD_API_KEY"
  [[ -n "$ENV_OFFLOAD_REMOTE" ]] && OFFLOAD_REMOTE="$ENV_OFFLOAD_REMOTE"
  [[ -n "$ENV_OFFLOAD_GITHUB_LOGIN" ]] && OFFLOAD_GITHUB_LOGIN="$ENV_OFFLOAD_GITHUB_LOGIN"
}

logout() {
  if [[ ! -f "$CONFIG" ]]; then
    echo "No offload login found at $CONFIG."
    return 0
  fi

  local backup
  backup="$CONFIG.logged-out.$(date +%Y%m%d%H%M%S)"
  [[ ! -e "$backup" ]] || backup="$backup.$$"
  mv "$CONFIG" "$backup"
  if [[ -n "${CONFIG_OFFLOAD_GITHUB_LOGIN:-}" ]]; then
    echo "Logged out locally from offload account $CONFIG_OFFLOAD_GITHUB_LOGIN."
  else
    echo "Logged out locally from offload."
  fi
  echo "Moved previous config to $backup."
  echo "Run /claude-go-brr:setup login to sign in again."
}

if [[ $# -eq 1 && -z "${1:-}" ]]; then
  shift
fi

case "${1:-}" in
  "")
    if [[ -n "${OFFLOAD_API_KEY:-}" ]] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      require_matching_saved_login
      "$CLIENT" github install-url --remote "${OFFLOAD_REMOTE:-origin}"
      exit 0
    fi
    RESP="$("$CLIENT" auth start "$@")"
    printf '%s\n' "$RESP"
    DEVICE_CODE="$(printf '%s\n' "$RESP" | awk -F= '/^device_code=/ {print $2; exit}')"
    if [[ -n "$DEVICE_CODE" ]]; then
      echo
      echo "Open the login_url above in your browser. After GitHub says login complete, run:"
      echo "/claude-go-brr:setup $DEVICE_CODE"
    fi
    ;;
  start|login)
    [[ $# -gt 0 ]] && shift || true
    RESP="$("$CLIENT" auth start "$@")"
    printf '%s\n' "$RESP"
    DEVICE_CODE="$(printf '%s\n' "$RESP" | awk -F= '/^device_code=/ {print $2; exit}')"
    if [[ -n "$DEVICE_CODE" ]]; then
      echo
      echo "Open the login_url above in your browser. After GitHub says login complete, run:"
      echo "/claude-go-brr:setup $DEVICE_CODE"
    fi
    ;;
  -h|--help|help)
    echo "usage: setup.sh [start|login|logout|DEVICE_CODE]"
    ;;
  logout)
    logout
    ;;
  *)
    "$CLIENT" auth exchange "$1" --name "$NAME"
    echo
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      reload_saved_config
      require_matching_saved_login
      echo "Requesting GitHub App install URL for this repo..."
      "$CLIENT" github install-url --remote "${OFFLOAD_REMOTE:-origin}" || {
        echo
        echo "Auth is saved, but repo approval URL could not be created automatically."
        echo "Run /claude-go-brr:setup from the target repo, or run:"
        echo "$CLIENT github install-url --repo OWNER/REPO"
      }
    else
      echo "Auth saved. From the target repo, run /claude-go-brr:setup again or run:"
      echo "$CLIENT github install-url --repo OWNER/REPO"
    fi
    ;;
esac
