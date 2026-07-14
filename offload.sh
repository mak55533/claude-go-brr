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

apply_events_response() {
  local body_file="$1" run_id="$2" requested_after="$3" state_file="$4" log_file="$5"

  python3 - "$body_file" "$run_id" "$requested_after" "$state_file" "$log_file" <<'PY'
import json
import math
import os
from pathlib import Path
import re
import sys

body_path, requested_run_id, requested_after, state_path, log_path = sys.argv[1:]
requested_after = int(requested_after)
state_path = Path(state_path)
log_path = Path(log_path)

def protocol_error(message):
    print(f"protocol error: {message}", file=sys.stderr)
    raise SystemExit(65)

def integer(value):
    return isinstance(value, int) and not isinstance(value, bool)

try:
    doc = json.loads(Path(body_path).read_text())
except Exception as exc:
    protocol_error(f"events response is not valid JSON: {exc}")

if not isinstance(doc, dict):
    protocol_error("events response must be an object")
run = doc.get("run")
if not isinstance(run, dict):
    protocol_error("events response run must be an object")
for field in ("run_id", "status", "terminal", "worker_id", "updated_at", "finished_at"):
    if field not in run:
        protocol_error(f"events response run.{field} is required")
if run["run_id"] != requested_run_id:
    protocol_error(f"events response run_id does not match {requested_run_id}")
if not isinstance(run["status"], str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", run["status"]):
    protocol_error("events response run.status must be a status identifier")
if not isinstance(run["terminal"], bool):
    protocol_error("events response run.terminal must be boolean")
if run["worker_id"] is not None and not isinstance(run["worker_id"], str):
    protocol_error("events response run.worker_id must be a string or null")
if isinstance(run["updated_at"], bool) or not isinstance(run["updated_at"], (int, float)) or not math.isfinite(run["updated_at"]):
    protocol_error("events response run.updated_at must be a finite number")
if run["finished_at"] is not None and (isinstance(run["finished_at"], bool) or not isinstance(run["finished_at"], (int, float)) or not math.isfinite(run["finished_at"])):
    protocol_error("events response run.finished_at must be a finite number or null")

batches = doc.get("batches")
last_seq = doc.get("last_seq")
has_more = doc.get("has_more")
if not isinstance(batches, list):
    protocol_error("events response batches must be an array")
if not integer(last_seq) or last_seq < 0:
    protocol_error("events response last_seq must be a non-negative integer")
if not isinstance(has_more, bool):
    protocol_error("events response has_more must be boolean")
if run["terminal"]:
    if "result" not in doc or not isinstance(doc["result"], dict):
        protocol_error("terminal events response result must be an object")
    result = doc["result"]
    if "patch" in result and not isinstance(result["patch"], str):
        protocol_error("terminal events response result.patch must be a string")
    if "prompt_results" in result and not isinstance(result["prompt_results"], list):
        protocol_error("terminal events response result.prompt_results must be an array")
elif "result" in doc:
    protocol_error("non-terminal events response must not include result")

new_events = []
previous_seq = requested_after
for batch_index, batch in enumerate(batches):
    if not isinstance(batch, dict):
        protocol_error(f"batch {batch_index} must be an object")
    seq = batch.get("seq")
    if not integer(seq) or seq != previous_seq + 1:
        protocol_error(f"batch {batch_index} seq must be contiguous after {previous_seq}")
    events = batch.get("events")
    if not isinstance(events, list):
        protocol_error(f"batch {seq} events must be an array")
    prompt_indexes = set()
    batch_events = []
    for event_index, event in enumerate(events):
        if not isinstance(event, dict):
            protocol_error(f"batch {seq} event {event_index} must be an object")
        prompt_index = event.get("prompt_index")
        text = event.get("text")
        if not integer(prompt_index) or prompt_index < 0:
            protocol_error(f"batch {seq} event {event_index} prompt_index must be a non-negative integer")
        if prompt_index in prompt_indexes:
            protocol_error(f"batch {seq} contains duplicate prompt_index {prompt_index}")
        if not isinstance(text, str):
            protocol_error(f"batch {seq} event {event_index} text must be a string")
        prompt_indexes.add(prompt_index)
        batch_events.append({"seq": seq, "prompt_index": prompt_index, "text": text})
    new_events.extend(batch_events)
    previous_seq = seq

expected_last_seq = batches[-1]["seq"] if batches else requested_after
if last_seq != expected_last_seq:
    protocol_error(f"events response last_seq must equal {expected_last_seq}")

try:
    state = json.loads(state_path.read_text()) if state_path.exists() else {"after": 0, "events": []}
    committed_after = state["after"]
    committed_events = state["events"]
    if not integer(committed_after) or not isinstance(committed_events, list):
        raise ValueError("invalid polling state")
except Exception as exc:
    protocol_error(f"local polling state is invalid: {exc}")

if committed_after == requested_after:
    state = {"after": last_seq, "events": committed_events + new_events}
    temporary_state = state_path.with_name(f"{state_path.name}.{os.getpid()}.tmp")
    temporary_state.write_text(json.dumps(state))
    os.replace(temporary_state, state_path)
elif committed_after == last_seq and batches:
    # A previous application committed before its caller observed success.
    # Re-render the committed state without duplicating sequence batches.
    state = {"after": committed_after, "events": committed_events}
else:
    protocol_error(f"local polling cursor {committed_after} does not match requested cursor {requested_after}")

ansi = re.compile(r"\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")
rendered = []
for event in state["events"]:
    text = ansi.sub("", event["text"])
    text = "".join(char for char in text if char in "\n\t" or ord(char) >= 32)
    rendered.append(f"[prompt {event['prompt_index']}] {text}")
    if text and not text.endswith("\n"):
        rendered.append("\n")
rendered = "".join(rendered)
committed_log = log_path.read_text() if log_path.exists() else ""
if not rendered.startswith(committed_log):
    protocol_error("local worker log does not match committed polling state")
with log_path.open("a") as stream:
    stream.write(rendered[len(committed_log):])

print(f"{last_seq}\t{run['status']}\t{int(run['terminal'])}\t{int(has_more)}")
PY
}

json_error_message() {
  python3 -c 'import json, pathlib, sys
try:
    doc = json.loads(pathlib.Path(sys.argv[1]).read_text())
    print(doc.get("error", "") if isinstance(doc, dict) else "")
except Exception:
    print("")' "$1"
}

retry_after_seconds() {
  python3 - "$1" <<'PY'
import email.utils
import math
from pathlib import Path
import time
import sys

value = ""
for line in Path(sys.argv[1]).read_text(errors="replace").splitlines():
    if line.lower().startswith("retry-after:"):
        value = line.split(":", 1)[1].strip()
if value.isdigit():
    print(value)
elif value:
    try:
        print(max(0, math.ceil(email.utils.parsedate_to_datetime(value).timestamp() - time.time())))
    except Exception:
        pass
PY
}

bounded_backoff() {
  python3 -c 'import sys
attempt = int(sys.argv[1])
try:
    base = max(1.0, float(sys.argv[2]))
except ValueError:
    base = 1.0
print(min(30.0, base * (2 ** min(attempt - 1, 5))))' "$1" "$POLL_INTERVAL"
}

poll_sleep() {
  local delay="$1" started="$2" remaining
  remaining=$(( POLL_TIMEOUT - (SECONDS - started) ))
  (( remaining > 0 )) || return 0
  delay="$(python3 -c 'import sys; print(min(float(sys.argv[1]), float(sys.argv[2])))' "$delay" "$remaining")"
  sleep "$delay"
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

save_run_result() {
  local body_file="$1" log_file="$2" patch_file="$3" output_file="$4"

  python3 - "$body_file" "$log_file" "$patch_file" "$output_file" <<'PY'
import json
from pathlib import Path
import sys

body_path, log_path, patch_path, output_path = map(Path, sys.argv[1:])
doc = json.loads(body_path.read_text())
if not doc["run"]["terminal"] or not isinstance(doc.get("result"), dict):
    print("protocol error: attempted to consume a non-terminal run result", file=sys.stderr)
    raise SystemExit(65)
result = doc["result"]
patch = result.get("patch", "")
if not isinstance(patch, str):
    print("protocol error: terminal result.patch must be a string", file=sys.stderr)
    raise SystemExit(65)
patch_path.write_text(patch)
output_path.write_text(log_path.read_text())
PY
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
  local folder wait individual_instances prompt branch dirty_files git_ref body resp run_id elapsed status log_file log_prefix
  local after apply_meta event_code error_message has_more header_file next_after poll_dir remaining retry_attempt retry_delay started state_file terminal
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

  log_prefix="${run_id//[^A-Za-z0-9._-]/-}"
  log_file="$(mktemp "${TMPDIR:-/tmp}/offload-${log_prefix}.XXXXXX")"
  echo "  worker log: $log_file"

  echo "> waiting for completion (Ctrl-C to stop waiting; the run continues remotely)..."
  poll_dir="$(mktemp -d "${TMPDIR:-/tmp}/offload-poll-${log_prefix}.XXXXXX")"
  header_file="$poll_dir/headers"
  state_file="$poll_dir/state.json"
  trap 'rm -rf "$poll_dir"' EXIT
  trap 'exit 130' INT TERM HUP
  after=0
  retry_attempt=0
  started=$SECONDS
  while (( SECONDS - started < POLL_TIMEOUT )); do
    remaining=$(( POLL_TIMEOUT - (SECONDS - started) ))
    : > "$header_file"
    : > "$poll_dir/body"
    if ! event_code="$(curl -sS --max-time "$remaining" -H "Authorization: Bearer $OFFLOAD_API_KEY" -H "Accept: application/json" --dump-header "$header_file" --output "$poll_dir/body" --write-out '%{http_code}' "$(api_url)/v1/runs/$run_id/events?after=$after&limit_bytes=262144")"; then
      retry_attempt=$(( retry_attempt + 1 ))
      retry_delay="$(bounded_backoff "$retry_attempt")"
      echo "> polling request failed; retrying after ${retry_delay}s with after=$after" >&2
      poll_sleep "$retry_delay" "$started"
      continue
    fi

    case "$event_code" in
      200)
        apply_meta="$(apply_events_response "$poll_dir/body" "$run_id" "$after" "$state_file" "$log_file")" || exit $?
        IFS=$'\t' read -r next_after status terminal has_more <<<"$apply_meta"
        after="$next_after"
        retry_attempt=0
        elapsed=$(( SECONDS - started ))
        printf '  ...%s (%ds)\r' "$status" "$elapsed"
        if [[ "$has_more" -eq 1 ]]; then
          continue
        fi
        if [[ "$terminal" -eq 1 ]]; then
          echo
          if [[ "$status" == "ok_patch" || "$status" == "ok" || "$status" == "ok_no_pr" ]]; then
            local out_dir patch_file output_file
            out_dir="$(git rev-parse --git-path offload)"
            mkdir -p "$out_dir"
            patch_file="$out_dir/$run_id.patch"
            output_file="$out_dir/$run_id.output.txt"
            save_run_result "$poll_dir/body" "$log_file" "$patch_file" "$output_file"
            echo "OK $status done."
            if [[ "$status" == "ok_patch" && -s "$patch_file" ]]; then
              echo "  patch:  $patch_file"
              echo "  apply:  git apply $patch_file"
            elif [[ "$status" == "ok_patch" ]]; then
              echo "  patch:  no changes"
            fi
            [[ -s "$output_file" ]] && echo "  output: $output_file"
            echo "  worker log: $log_file"
            exit 0
          fi
          if [[ "$status" == "env_failed" ]]; then
            echo "x run $status - project environment injection failed; manage values in the browser: $(env_settings_url "$folder_id")" >&2
          else
            echo "x run $status - inspect the worker log: $log_file" >&2
          fi
          exit 1
        fi
        poll_sleep "$POLL_INTERVAL" "$started"
        ;;
      400)
        error_message="$(json_error_message "$poll_dir/body")"
        echo "protocol error: polling request rejected (HTTP 400${error_message:+: $error_message})" >&2
        exit 65
        ;;
      401)
        error_message="$(json_error_message "$poll_dir/body")"
        echo "authentication error: polling API key rejected (HTTP 401${error_message:+: $error_message})" >&2
        exit 77
        ;;
      403)
        error_message="$(json_error_message "$poll_dir/body")"
        echo "authorization error: cannot access run $run_id (HTTP 403${error_message:+: $error_message})" >&2
        exit 77
        ;;
      404)
        error_message="$(json_error_message "$poll_dir/body")"
        echo "not-found protocol error: unknown run_id $run_id (HTTP 404${error_message:+: $error_message})" >&2
        exit 65
        ;;
      429)
        retry_attempt=$(( retry_attempt + 1 ))
        retry_delay="$(retry_after_seconds "$header_file")"
        [[ -n "$retry_delay" ]] || retry_delay="$(bounded_backoff "$retry_attempt")"
        echo "> polling rate limited; retrying after ${retry_delay}s with after=$after" >&2
        poll_sleep "$retry_delay" "$started"
        ;;
      5??)
        retry_attempt=$(( retry_attempt + 1 ))
        retry_delay="$(bounded_backoff "$retry_attempt")"
        echo "> polling API returned HTTP $event_code; retrying after ${retry_delay}s with after=$after" >&2
        poll_sleep "$retry_delay" "$started"
        ;;
      *)
        error_message="$(json_error_message "$poll_dir/body")"
        echo "protocol error: polling API returned HTTP $event_code${error_message:+: $error_message}" >&2
        exit 65
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
