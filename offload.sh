#!/usr/bin/env bash
#
# offload.sh - CLI client for the agent offload host API.
#
# One-time setup:
#   offload.sh auth start
#   offload.sh auth exchange DEVICE_CODE --name my-laptop
#   offload.sh github install-url --repo OWNER/REPO
#
# Project environment variables:
#   offload.sh env
#   offload.sh env -d /path/to/folder
#   Set values once per project in the printed browser URL. The CLI shows key names only.
#   Values are injected automatically on every run; browser changes apply to the next run.
#
# Submit and inspect runs:
#   offload.sh "implement the thing"
#   offload.sh submit -d /path/to/folder "fix the bug in checkout"
#   offload.sh submit --individual-instances "run each item independently"
#   offload.sh --no-wait "long task"
#   offload.sh runs
#   offload.sh status RUN_ID
#
# Config (env or ~/.config/offload/config):
#   OFFLOAD_API_URL   e.g. https://accelerator.functio.ai (default for auth)
#   OFFLOAD_API_KEY   host-issued client API key
#   OFFLOAD_GITHUB_LOGIN authenticated GitHub login, saved when returned by auth
#   OFFLOAD_REMOTE    optional explicit git remote override
#
set -Eeuo pipefail

DEFAULT_API_URL="https://accelerator.functio.ai"
CONFIG="${OFFLOAD_CONFIG:-$HOME/.config/offload/config}"
ENV_OFFLOAD_API_URL="${OFFLOAD_API_URL-}"
ENV_OFFLOAD_API_KEY="${OFFLOAD_API_KEY-}"
ENV_OFFLOAD_REMOTE="${OFFLOAD_REMOTE-}"
ENV_OFFLOAD_GITHUB_LOGIN="${OFFLOAD_GITHUB_LOGIN-}"
ENV_OFFLOAD_POLL_INTERVAL="${OFFLOAD_POLL_INTERVAL-}"
ENV_OFFLOAD_POLL_TIMEOUT="${OFFLOAD_POLL_TIMEOUT-}"
# shellcheck disable=SC1090
[[ -f "$CONFIG" ]] && source "$CONFIG"
[[ -n "$ENV_OFFLOAD_API_URL" ]] && OFFLOAD_API_URL="$ENV_OFFLOAD_API_URL"
[[ -n "$ENV_OFFLOAD_API_KEY" ]] && OFFLOAD_API_KEY="$ENV_OFFLOAD_API_KEY"
[[ -n "$ENV_OFFLOAD_REMOTE" ]] && OFFLOAD_REMOTE="$ENV_OFFLOAD_REMOTE"
[[ -n "$ENV_OFFLOAD_GITHUB_LOGIN" ]] && OFFLOAD_GITHUB_LOGIN="$ENV_OFFLOAD_GITHUB_LOGIN"
[[ -n "$ENV_OFFLOAD_POLL_INTERVAL" ]] && OFFLOAD_POLL_INTERVAL="$ENV_OFFLOAD_POLL_INTERVAL"
[[ -n "$ENV_OFFLOAD_POLL_TIMEOUT" ]] && OFFLOAD_POLL_TIMEOUT="$ENV_OFFLOAD_POLL_TIMEOUT"

POLL_INTERVAL="${OFFLOAD_POLL_INTERVAL:-5}"
POLL_TIMEOUT="${OFFLOAD_POLL_TIMEOUT:-3600}"

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit "${1:-0}"
}

api_url() {
  printf '%s' "${OFFLOAD_API_URL:-$DEFAULT_API_URL}" | sed 's:/*$::'
}

require_api_key() {
  [[ -n "${OFFLOAD_API_KEY:-}" ]] && return
  echo "error: OFFLOAD_API_KEY not set (see $CONFIG or run: $0 auth start)" >&2
  exit 78
}

auth_headers() {
  require_api_key
  printf '%s\n' "-H" "Authorization: Bearer $OFFLOAD_API_KEY"
}

json_field() {
  python3 -c 'import json, sys
field = sys.argv[1]
doc = json.load(sys.stdin)
value = doc
for part in field.split("."):
    if isinstance(value, dict):
        value = value.get(part, "")
    else:
        value = ""
        break
if value is None:
    value = ""
print(json.dumps(value) if isinstance(value, (dict, list)) else value)' "$1"
}

render_live_events() {
  python3 -c '
import json
import re
import sys

doc = json.load(sys.stdin)
ansi = re.compile(r"\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")
for event in doc.get("events") or []:
    if not isinstance(event, dict):
        continue
    kind = event.get("kind")
    text = ansi.sub("", str(event.get("text") or ""))
    text = "".join(char for char in text if char in "\n\t" or ord(char) >= 32)
    if kind == "claude_log" and text:
        index = event.get("prompt_index", "?")
        sys.stdout.write(f"[prompt {index}] {text}")
        if not text.endswith("\n"):
            sys.stdout.write("\n")
    elif kind == "logs_truncated":
        message = text or "log stream truncated"
        sys.stdout.write(f"[live logs] {message}\n")
sys.stdout.flush()
'
}

repo_meta() {
  python3 - "$1" <<'PY'
import re
import sys
from urllib.parse import urlparse

url = sys.argv[1]
owner = repo = ""
if url.startswith("git@github.com:"):
    path = url.removeprefix("git@github.com:")
elif url.startswith("ssh://"):
    parsed = urlparse(url)
    path = parsed.path.lstrip("/") if parsed.hostname == "github.com" else ""
elif url.startswith("https://") or url.startswith("http://"):
    parsed = urlparse(url)
    path = parsed.path.lstrip("/") if parsed.hostname == "github.com" else ""
else:
    path = ""

if path:
    match = re.fullmatch(r"([^/]+)/([^/]+?)(?:\.git)?", path)
    if match:
        owner, repo = match.group(1), match.group(2)

if not owner or not repo:
    print("error: OFFLOAD_REMOTE must point to a GitHub repo (git@github.com:owner/repo.git or https://github.com/owner/repo.git)", file=sys.stderr)
    sys.exit(65)

print(f"{owner}\t{repo}\thttps://github.com/{owner}/{repo}.git")
PY
}

current_repo_owner_name() {
  local remote="$1"
  local repo_url
  repo_url="$(git remote get-url "$remote")"
  IFS=$'\t' read -r owner repo _ < <(repo_meta "$repo_url")
  printf '%s\t%s\n' "$owner" "$repo"
}

github_remotes() {
  local remote repo_url meta
  while IFS= read -r remote; do
    [[ -n "$remote" ]] || continue
    repo_url="$(git remote get-url "$remote" 2>/dev/null || true)"
    [[ -n "$repo_url" ]] || continue
    meta="$(repo_meta "$repo_url" 2>/dev/null || true)"
    [[ -n "$meta" ]] || continue
    printf '%s\t%s\n' "$remote" "$meta"
  done < <(git remote)
}

select_github_remote() {
  local explicit="${OFFLOAD_REMOTE:-}"
  local login="${OFFLOAD_GITHUB_LOGIN:-}"
  local login_lc remote owner repo clone_url line count match_count selected
  if [[ -n "$explicit" ]]; then
    clone_url="$(git remote get-url "$explicit")"
    IFS=$'\t' read -r owner repo clone_url < <(repo_meta "$clone_url")
    SELECTED_REMOTE="$explicit"
    SELECTED_REPO_OWNER="$owner"
    SELECTED_REPO_NAME="$repo"
    SELECTED_REPO_CLONE_URL="$clone_url"
    return
  fi

  count=0
  match_count=0
  login_lc="$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')"
  while IFS=$'\t' read -r remote owner repo clone_url; do
    [[ -n "$remote" ]] || continue
    count=$(( count + 1 ))
    selected="$remote"$'\t'"$owner"$'\t'"$repo"$'\t'"$clone_url"
    if [[ -n "$login_lc" && "$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')" == "$login_lc" ]]; then
      match_count=$(( match_count + 1 ))
      line="$selected"
    elif [[ -z "${line:-}" ]]; then
      line="$selected"
    fi
  done < <(github_remotes)

  if [[ "$match_count" -eq 1 ]]; then
    IFS=$'\t' read -r SELECTED_REMOTE SELECTED_REPO_OWNER SELECTED_REPO_NAME SELECTED_REPO_CLONE_URL <<<"$line"
    return
  fi
  if [[ "$count" -eq 1 ]]; then
    IFS=$'\t' read -r SELECTED_REMOTE SELECTED_REPO_OWNER SELECTED_REPO_NAME SELECTED_REPO_CLONE_URL <<<"$line"
    return
  fi

  if [[ "$count" -eq 0 ]]; then
    echo "error: no GitHub remotes found; add a GitHub remote or set OFFLOAD_REMOTE" >&2
  elif [[ "$match_count" -gt 1 ]]; then
    echo "error: multiple GitHub remotes match OFFLOAD_GITHUB_LOGIN=$login; set OFFLOAD_REMOTE" >&2
  else
    echo "error: multiple GitHub remotes found and none uniquely match OFFLOAD_GITHUB_LOGIN=${login:-<unset>}; set OFFLOAD_REMOTE" >&2
  fi
  github_remotes | awk -F '\t' '{ printf "  %s -> %s/%s\n", $1, $2, $3 }' >&2
  exit 65
}

resolve_project_context() {
  local folder="$1"
  local toplevel rel repo_slug

  cd "$folder"
  PROJECT_FOLDER="$(pwd -P)"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "error: $PROJECT_FOLDER is not a git repo" >&2; exit 65; }

  toplevel="$(git rev-parse --show-toplevel)"
  rel="${PROJECT_FOLDER#"$toplevel"}"
  rel="${rel#/}"
  select_github_remote

  PROJECT_TOPLEVEL="$toplevel"
  PROJECT_REL="$rel"
  PROJECT_REMOTE="$SELECTED_REMOTE"
  PROJECT_REPO_OWNER="$SELECTED_REPO_OWNER"
  PROJECT_REPO_NAME="$SELECTED_REPO_NAME"
  PROJECT_REPO_CLONE_URL="$SELECTED_REPO_CLONE_URL"
  repo_slug="$PROJECT_REPO_NAME"
  PROJECT_REPO_SLUG="$repo_slug"
  PROJECT_FOLDER_ID="$repo_slug${rel:+--${rel//\//-}}"
  PROJECT_FOLDER_ID="$(printf '%s' "$PROJECT_FOLDER_ID" | tr -c 'A-Za-z0-9._-' '-')"
}

env_settings_url() {
  printf '%s/settings/projects/%s' "$(api_url)" "$1"
}

auth_start() {
  local api
  api="$(api_url)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --api-url) api="${2%/}"; shift 2 ;;
      -h|--help) echo "usage: $0 auth start [--api-url URL]"; exit 0 ;;
      *) echo "unknown flag: $1" >&2; exit 64 ;;
    esac
  done

  local resp login_url device_code
  resp="$(curl -fsS -X POST "$api/v1/auth/cli/start" -H "Content-Type: application/json" -d '{}')"
  login_url="$(printf '%s' "$resp" | json_field login_url)"
  device_code="$(printf '%s' "$resp" | json_field device_code)"
  printf '%s\n' "$resp"
  [[ -n "$login_url" ]] && echo "login_url=$login_url"
  [[ -n "$device_code" ]] && echo "device_code=$device_code"
}

save_config() {
  local api="$1"
  local token="$2"
  local github_login="${3:-${OFFLOAD_GITHUB_LOGIN:-}}"
  mkdir -p "$(dirname "$CONFIG")"
  umask 077
  {
    printf 'OFFLOAD_API_URL=%s\n' "$api"
    printf 'OFFLOAD_API_KEY=%s\n' "$token"
    [[ -n "${OFFLOAD_REMOTE:-}" ]] && printf 'OFFLOAD_REMOTE=%s\n' "$OFFLOAD_REMOTE"
    [[ -n "$github_login" ]] && printf 'OFFLOAD_GITHUB_LOGIN=%s\n' "$github_login"
    [[ -n "${OFFLOAD_POLL_INTERVAL:-}" ]] && printf 'OFFLOAD_POLL_INTERVAL=%s\n' "$OFFLOAD_POLL_INTERVAL"
    [[ -n "${OFFLOAD_POLL_TIMEOUT:-}" ]] && printf 'OFFLOAD_POLL_TIMEOUT=%s\n' "$OFFLOAD_POLL_TIMEOUT"
  } > "$CONFIG"
  chmod 600 "$CONFIG"
  echo "saved config: $CONFIG"
}

auth_exchange() {
  local api name device_code resp token github_login
  api="$(api_url)"
  name="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo client)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --api-url) api="${2%/}"; shift 2 ;;
      --name) name="$2"; shift 2 ;;
      -h|--help) echo "usage: $0 auth exchange DEVICE_CODE [--name NAME] [--api-url URL]"; exit 0 ;;
      -* ) echo "unknown flag: $1" >&2; exit 64 ;;
      * ) device_code="${device_code:-$1}"; shift ;;
    esac
  done
  [[ -n "${device_code:-}" ]] || { echo "error: missing DEVICE_CODE" >&2; exit 64; }

  resp="$(python3 - "$device_code" "$name" <<'PY' | curl -fsS -X POST "$api/v1/auth/cli/exchange" -H "Content-Type: application/json" -d @-
import json
import sys

print(json.dumps({"device_code": sys.argv[1], "name": sys.argv[2]}))
PY
)"
  token="$(printf '%s' "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("token") or d.get("api_key") or d.get("client_key") or d.get("offload_api_key") or "")')"
  github_login="$(printf '%s' "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); u=d.get("user") or {}; print(d.get("github_login") or d.get("user_login") or d.get("login") or d.get("account_login") or u.get("login") or "")')"
  [[ -n "$token" ]] || { echo "error: exchange response did not include a token" >&2; printf '%s\n' "$resp" >&2; exit 1; }
  save_config "$api" "$token" "$github_login"
}

auth_login() {
  local api name start_resp login_url device_code
  api="$(api_url)"
  name="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo client)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --api-url) api="${2%/}"; shift 2 ;;
      --name) name="$2"; shift 2 ;;
      -h|--help) echo "usage: $0 auth login [--name NAME] [--api-url URL]"; exit 0 ;;
      *) echo "unknown flag: $1" >&2; exit 64 ;;
    esac
  done

  start_resp="$(curl -fsS -X POST "$api/v1/auth/cli/start" -H "Content-Type: application/json" -d '{}')"
  login_url="$(printf '%s' "$start_resp" | json_field login_url)"
  device_code="$(printf '%s' "$start_resp" | json_field device_code)"
  [[ -n "$login_url" && -n "$device_code" ]] || { echo "error: auth start response missing login_url or device_code" >&2; printf '%s\n' "$start_resp" >&2; exit 1; }
  echo "Open this URL in your browser:"
  echo "$login_url"
  echo "device_code=$device_code"
  if [[ -t 0 ]]; then
    read -r -p "Press Enter after GitHub says login complete..."
  fi
  auth_exchange "$device_code" --name "$name" --api-url "$api"
}

auth_cmd() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    start) auth_start "$@" ;;
    exchange) auth_exchange "$@" ;;
    login) auth_login "$@" ;;
    -h|--help|"") echo "usage: $0 auth {start|exchange|login}"; exit 0 ;;
    *) echo "unknown auth command: $sub" >&2; exit 64 ;;
  esac
}

github_install_url() {
  local owner repo repo_arg remote api resp install_url
  remote="${OFFLOAD_REMOTE:-}"
  api="$(api_url)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo_arg="$2"; shift 2 ;;
      --owner) owner="$2"; shift 2 ;;
      --name|--repo-name) repo="$2"; shift 2 ;;
      --remote) OFFLOAD_REMOTE="$2"; remote="$2"; shift 2 ;;
      -h|--help) echo "usage: $0 github install-url [--repo OWNER/REPO] [--remote REMOTE]"; exit 0 ;;
      *) echo "unknown flag: $1" >&2; exit 64 ;;
    esac
  done
  if [[ -n "${repo_arg:-}" ]]; then
    owner="${repo_arg%%/*}"
    repo="${repo_arg#*/}"
  fi
  if [[ -z "${owner:-}" || -z "${repo:-}" || "$owner" == "$repo" ]]; then
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "error: --repo OWNER/REPO is required outside a git repo" >&2; exit 65; }
    [[ -n "$remote" ]] && OFFLOAD_REMOTE="$remote"
    select_github_remote
    owner="$SELECTED_REPO_OWNER"
    repo="$SELECTED_REPO_NAME"
  fi
  require_api_key
  resp="$(python3 - "$owner" "$repo" <<'PY' | curl -fsS -X POST "$api/v1/github/app/install-url" -H "Authorization: Bearer $OFFLOAD_API_KEY" -H "Content-Type: application/json" -d @-
import json
import sys

print(json.dumps({"owner": sys.argv[1], "repo": sys.argv[2]}))
PY
)"
  install_url="$(printf '%s' "$resp" | json_field install_url)"
  printf '%s\n' "$resp"
  [[ -n "$install_url" ]] && echo "install_url=$install_url"
}

github_cmd() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    install-url) github_install_url "$@" ;;
    -h|--help|"") echo "usage: $0 github install-url [--repo OWNER/REPO]"; exit 0 ;;
    *) echo "unknown github command: $sub" >&2; exit 64 ;;
  esac
}

runs_list() {
  require_api_key
  curl -fsS "$(api_url)/v1/runs" -H "Authorization: Bearer $OFFLOAD_API_KEY"
  echo
}

run_status() {
  local run_id="${1:-}"
  [[ -n "$run_id" ]] || { echo "usage: $0 status RUN_ID" >&2; exit 64; }
  require_api_key
  curl -fsS "$(api_url)/v1/runs/$run_id" -H "Authorization: Bearer $OFFLOAD_API_KEY"
  echo
}

print_env_metadata() {
  local folder_id="$1"

  python3 -c '
import json
import sys

folder_id = sys.argv[1]
doc = json.load(sys.stdin)
keys = doc.get("keys") or []
count = doc.get("count")
if count is None:
    count = len(keys)

print(f"folder_id={doc.get('folder_id') or folder_id}")
if not keys:
    print(f"No env vars configured (count={count}).")
else:
    print(f"Configured env vars (count={count}):")
    for item in keys:
        key = item.get("key") if isinstance(item, dict) else str(item)
        if key:
            print(f"  {key}")
' "$folder_id"
}

print_no_env_metadata() {
  local folder_id="$1"
  echo "folder_id=$folder_id"
  echo "No env vars configured (count=0)."
}

env_cmd() {
  local folder resp http_code body settings_url
  folder="$PWD"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--dir) folder="$2"; shift 2 ;;
      -h|--help) echo "usage: $0 env [-d DIR]"; exit 0 ;;
      *) echo "unknown flag: $1" >&2; exit 64 ;;
    esac
  done

  require_api_key
  resolve_project_context "$folder"
  settings_url="$(env_settings_url "$PROJECT_FOLDER_ID")"

  if ! resp="$(curl -sS -H "Authorization: Bearer $OFFLOAD_API_KEY" -w $'\n%{http_code}' "$(api_url)/v1/folders/$PROJECT_FOLDER_ID/env")"; then
    echo "error: failed to fetch env metadata" >&2
    exit 1
  fi
  http_code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"

  if [[ "$http_code" == "404" || -z "$body" ]]; then
    print_no_env_metadata "$PROJECT_FOLDER_ID"
  elif [[ "$http_code" == 2* ]]; then
    printf '%s' "$body" | print_env_metadata "$PROJECT_FOLDER_ID"
  else
    echo "error: env metadata request failed with HTTP $http_code" >&2
    [[ -n "$body" ]] && printf '%s\n' "$body" >&2
    exit 1
  fi

  echo "settings_url=$settings_url"
  echo "Env variable values are managed in the browser only; this command shows key names and never accepts or prints values."
}

submit_cmd() {
  local folder wait individual_instances prompt branch dirty_files git_ref body resp run_id elapsed rec status
  local live_events log_cursor event_http event_code event_body next_cursor
  folder="$PWD"
  wait=1
  individual_instances=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--dir) folder="$2"; shift 2 ;;
      --no-wait) wait=0; shift ;;
      --individual-instances) individual_instances=1; shift ;;
      -h|--help) usage 0 ;;
      --) shift; break ;;
      -*) echo "unknown flag: $1" >&2; usage 64 ;;
      *) break ;;
    esac
  done

  prompt="${*:-}"
  [[ -n "$prompt" ]] || { echo "error: no task prompt given" >&2; usage 64; }
  require_api_key

  local toplevel rel repo_owner repo_name repo_clone_url repo_slug folder_id remote
  resolve_project_context "$folder"
  folder="$PROJECT_FOLDER"
  toplevel="$PROJECT_TOPLEVEL"
  rel="$PROJECT_REL"
  remote="$PROJECT_REMOTE"
  repo_owner="$PROJECT_REPO_OWNER"
  repo_name="$PROJECT_REPO_NAME"
  repo_clone_url="$PROJECT_REPO_CLONE_URL"
  repo_slug="$PROJECT_REPO_SLUG"
  folder_id="$PROJECT_FOLDER_ID"

  if ! branch="$(git symbolic-ref --quiet --short HEAD)"; then
    echo "error: detached HEAD - check out a branch before offloading" >&2
    exit 65
  fi

  dirty_files="$(git status --short)"
  if [[ -n "$dirty_files" ]]; then
    echo "> ignoring local uncommitted changes; cloud run uses GitHub $remote/$branch"
  fi

  git_ref="$branch"
  echo "> using GitHub ref $remote/$git_ref"

  body="$(python3 - "$folder_id" "$repo_owner" "$repo_name" "$rel" "$git_ref" "$prompt" "$individual_instances" <<'PY'
import json
import sys

body = {
    "folder_id": sys.argv[1],
    "provider": "github",
    "owner": sys.argv[2],
    "repo": sys.argv[3],
    "folder_path": sys.argv[4],
    "git_ref": sys.argv[5],
}
if sys.argv[7] == "1":
    body["individual_instances"] = True
    body["prompts"] = sys.argv[6].splitlines()
else:
    body["prompt"] = sys.argv[6]
print(json.dumps(body))
PY
)"

  echo "> submitting run (folder_id=$folder_id ref=$git_ref)..."
  resp="$(curl -fsS -H "Authorization: Bearer $OFFLOAD_API_KEY" -H "Content-Type: application/json" -X POST "$(api_url)/v1/runs" -d "$body")"
  run_id="$(printf '%s' "$resp" | json_field run_id)"
  [[ -n "$run_id" ]] || { echo "error: submit response missing run_id" >&2; printf '%s\n' "$resp" >&2; exit 1; }
  echo "  run_id=$run_id"

  if [[ "$wait" -eq 0 ]]; then
    echo "submitted. check later: $0 status $run_id"
    exit 0
  fi

  echo "> waiting for completion (Ctrl-C to stop waiting; the run continues remotely)..."
  elapsed=0
  live_events=1
  log_cursor=0
  while (( elapsed < POLL_TIMEOUT )); do
    sleep "$POLL_INTERVAL"
    elapsed=$(( elapsed + POLL_INTERVAL ))
    if [[ "$live_events" -eq 1 ]]; then
      if event_http="$(curl -sS -H "Authorization: Bearer $OFFLOAD_API_KEY" -w $'\n%{http_code}' \
        "$(api_url)/v1/runs/$run_id/events?after=$log_cursor&limit_bytes=262144")"; then
        event_code="${event_http##*$'\n'}"
        event_body="${event_http%$'\n'*}"
        case "$event_code" in
          200)
            printf '%s' "$event_body" | render_live_events
            next_cursor="$(printf '%s' "$event_body" | json_field next_cursor)"
            [[ "$next_cursor" =~ ^[0-9]+$ ]] && log_cursor="$next_cursor"
            ;;
          404|405) live_events=0 ;;
        esac
      fi
    fi
    rec="$(curl -fsS -H "Authorization: Bearer $OFFLOAD_API_KEY" "$(api_url)/v1/runs/$run_id")" || continue
    status="$(printf '%s' "$rec" | json_field status)"
    case "$status" in
      ok_patch)
        local out_dir patch_file output_file
        out_dir="$(git rev-parse --git-path offload)"
        mkdir -p "$out_dir"
        patch_file="$out_dir/$run_id.patch"
        output_file="$out_dir/$run_id.output.txt"
        PATCH_FILE="$patch_file" OUTPUT_FILE="$output_file" python3 -c '
import json
import os
from pathlib import Path
import sys

rec = json.load(sys.stdin)
Path(os.environ["PATCH_FILE"]).write_text(rec.get("patch", ""))
Path(os.environ["OUTPUT_FILE"]).write_text(rec.get("agent_output", ""))
' <<<"$rec"
        echo "OK done."
        if [[ -s "$patch_file" ]]; then
          echo "  patch:  $patch_file"
          echo "  apply:  git apply $patch_file"
        else
          echo "  patch:  no changes"
        fi
        if [[ -s "$output_file" ]]; then
          echo "  output: $output_file"
          echo
          echo "----- agent output -----"
          cat "$output_file"
          echo "------------------------"
        fi
        exit 0
        ;;
      ok|ok_no_pr)
        echo "OK done."
        printf '%s\n' "$rec"
        exit 0
        ;;
      run_failed|build_failed|error|auth_failed|env_failed|no_claude_wrapper|no_hybrid_proxy|no_claude_go_brr_binary|invalid_claude_go_brr_root|no_claude_binary|no_boto3|no_non_root_user|invalid_aws_config_dir)
        if [[ "$status" == "env_failed" ]]; then
          echo "x run $status - project environment injection failed; manage values in the browser: $(env_settings_url "$folder_id")" >&2
        else
          echo "x run $status - inspect the remote worker logs" >&2
        fi
        exit 1
        ;;
      queued|running|"")
        printf '  ...%s (%ds)\r' "${status:-pending}" "$elapsed"
        ;;
    esac
  done
  echo
  echo "still running after ${POLL_TIMEOUT}s; check later with run_id=$run_id" >&2
  exit 0
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    auth) shift; auth_cmd "$@" ;;
    github) shift; github_cmd "$@" ;;
    runs|list) shift; runs_list "$@" ;;
    status|get) shift; run_status "$@" ;;
    env) shift; env_cmd "$@" ;;
    submit) shift; submit_cmd "$@" ;;
    -h|--help) usage 0 ;;
    "" ) usage 64 ;;
    *) submit_cmd "$@" ;;
  esac
}

main "$@"
