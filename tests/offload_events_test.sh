#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
REQUESTS="$TMP/requests.jsonl"
SERVER_PID=""
CLIENT_PID=""

cleanup() {
  [[ -z "$CLIENT_PID" ]] || { kill "$CLIENT_PID" 2>/dev/null || true; wait "$CLIENT_PID" 2>/dev/null || true; }
  [[ -z "$SERVER_PID" ]] || { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; }
  find "$ROOT/.git/offload" -maxdepth 1 -type f -name 'test-*.patch' -delete 2>/dev/null || true
  find "$ROOT/.git/offload" -maxdepth 1 -type f -name 'test-*.output.txt' -delete 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

python3 - "$PORT" "$REQUESTS" <<'PY' &
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import socket
import sys
import threading
import time
from urllib.parse import parse_qs, urlparse

port = int(sys.argv[1])
requests_path = sys.argv[2]
runs = {}
lock = threading.Lock()
serial = 0

def run_record(run_id, status, terminal):
    return {
        "run_id": run_id,
        "status": status,
        "terminal": terminal,
        "worker_id": "test-worker" if status != "queued" else None,
        "updated_at": time.time(),
        "finished_at": time.time() if terminal else None,
    }

def events_response(run_id, status, terminal, batches, last_seq, has_more, patch=""):
    data = {
        "run": run_record(run_id, status, terminal),
        "batches": batches,
        "last_seq": last_seq,
        "has_more": has_more,
    }
    if terminal:
        data["result"] = {"patch": patch, "prompt_results": []}
    return data

class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def send_json(self, data, status=200, headers=None):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        global serial
        if self.path != "/v1/runs":
            self.send_json({"error": "not found"}, 404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length))
        scenario = body.get("prompt", "unknown")
        with lock:
            serial += 1
            run_id = f"test-{scenario}-{serial}"
            runs[run_id] = {"scenario": scenario, "polls": 0}
        self.send_json({"run_id": run_id})

    def do_GET(self):
        parsed = urlparse(self.path)
        parts = parsed.path.strip("/").split("/")
        if len(parts) == 3 and parts[:2] == ["v1", "runs"]:
            with lock:
                with open(requests_path, "a") as stream:
                    stream.write(json.dumps({"old_status_path": self.path, "time": time.monotonic()}) + "\n")
            self.send_json({"error": "separate status polling is forbidden"}, 418)
            return
        if len(parts) != 4 or parts[:2] != ["v1", "runs"] or parts[3] != "events" or parts[2] not in runs:
            self.send_json({"error": "not found"}, 404)
            return

        run_id = parts[2]
        query = parse_qs(parsed.query)
        after = int(query.get("after", ["-1"])[0])
        limit = int(query.get("limit_bytes", ["-1"])[0])
        with lock:
            record = runs[run_id]
            record["polls"] += 1
            poll = record["polls"]
            scenario = record["scenario"]
            with open(requests_path, "a") as stream:
                stream.write(json.dumps({
                    "scenario": scenario,
                    "poll": poll,
                    "after": after,
                    "limit": limit,
                    "accept": self.headers.get("Accept"),
                    "authorization": self.headers.get("Authorization"),
                    "time": time.monotonic(),
                }) + "\n")

        if scenario == "happy":
            if poll == 1:
                self.send_json(events_response(run_id, "queued", False, [], after, False))
            elif poll == 2:
                self.send_json(events_response(run_id, "running", False, [{"seq": 1, "events": [{"prompt_index": 0, "text": "first worker line\n"}, {"prompt_index": 1, "text": "<script>pwned()</script>\n"}]}], 1, True))
            elif poll == 3:
                self.send_json(events_response(run_id, "ok_patch", True, [{"seq": 2, "events": [{"prompt_index": 0, "text": "same delta\n"}, {"prompt_index": 1, "text": "prompt one final\n"}]}], 2, True, "premature patch\n"))
            else:
                self.send_json(events_response(run_id, "ok_patch", True, [{"seq": 3, "events": [{"prompt_index": 0, "text": "same delta\n"}]}], 3, False, "final patch\n"))
            return
        if scenario == "network_retry" and poll == 1:
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        if scenario == "server_retry" and poll == 1:
            self.send_json({"error": "temporary host failure"}, 500)
            return
        if scenario == "rate_limit" and poll == 1:
            self.send_json({"error": "slow down"}, 429, {"Retry-After": "1"})
            return
        if scenario in {"network_retry", "server_retry", "rate_limit"}:
            self.send_json(events_response(run_id, "ok", True, [{"seq": 1, "events": [{"prompt_index": 0, "text": f"{scenario} done\n"}]}], 1, False))
            return
        if scenario.startswith("http_"):
            status = int(scenario.split("_", 1)[1])
            self.send_json({"error": f"test {status}"}, status)
            return
        if scenario == "malformed":
            self.send_json(events_response(run_id, "running", False, [{"seq": 1, "events": [{"prompt_index": 0, "text": "must not commit\n"}, {"prompt_index": 1, "text": 7}]}], 1, False))
            return
        if scenario == "unknown_terminal":
            self.send_json(events_response(run_id, "custom_terminal_error", True, [], after, False))
            return
        if scenario == "cancel":
            self.send_json(events_response(run_id, "queued", False, [], after, False))
            return
        self.send_json({"error": "unknown scenario"}, 400)

ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
SERVER_PID=$!

for _ in {1..50}; do
  python3 -c 'import socket, sys; s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=0.1); s.close()' "$PORT" >/dev/null 2>&1 && break
  sleep 0.1
done

run_client() {
  local scenario="$1" expected_status="$2"
  RUN_OUTPUT="$TMP/$scenario.out"
  set +e
  (cd "$ROOT" && TMPDIR="$TMP" OFFLOAD_CONFIG="$TMP/config" OFFLOAD_API_URL="http://127.0.0.1:$PORT" OFFLOAD_API_KEY=test OFFLOAD_POLL_INTERVAL=1 OFFLOAD_POLL_TIMEOUT=8 ./offload.sh submit "$scenario") >"$RUN_OUTPUT" 2>&1
  RUN_STATUS=$?
  set -e
  [[ "$RUN_STATUS" -eq "$expected_status" ]] || fail "$scenario exited $RUN_STATUS, expected $expected_status: $(<"$RUN_OUTPUT")"
}

run_client happy 0
happy_output="$(<"$RUN_OUTPUT")"
happy_run_id="$(sed -n 's/^  run_id=//p' "$RUN_OUTPUT" | tail -n 1)"
happy_log="$(sed -n 's/^  worker log: //p' "$RUN_OUTPUT" | head -n 1)"
[[ -f "$happy_log" ]] || fail "happy worker log was not created"
[[ "$happy_output" != *"<script>"* ]] || fail "untrusted event text was printed into the process UI"
[[ "$(<"$happy_log")" == *'[prompt 0] first worker line'* ]] || fail "prompt 0 output missing"
[[ "$(<"$happy_log")" == *'[prompt 1] <script>pwned()</script>'* ]] || fail "prompt 1 text was not preserved as plain text"
[[ "$(grep -c '^\[prompt 0\] same delta$' "$happy_log")" -eq 2 ]] || fail "identical deltas were deduplicated or duplicated"
[[ "$(<"$ROOT/.git/offload/$happy_run_id.patch")" == "final patch" ]] || fail "terminal result was consumed before stored batches were drained"
[[ "$(<"$ROOT/.git/offload/$happy_run_id.output.txt")" == "$(<"$happy_log")" ]] || fail "saved output differs from the committed live output"

run_client network_retry 0
[[ "$(<"$RUN_OUTPUT")" == *'retrying after 1.0s with after=0'* ]] || fail "network retry did not retain cursor 0"
run_client server_retry 0
[[ "$(<"$RUN_OUTPUT")" == *'HTTP 500; retrying after 1.0s with after=0'* ]] || fail "500 retry did not retain cursor 0"
run_client rate_limit 0
[[ "$(<"$RUN_OUTPUT")" == *'rate limited; retrying after 1s with after=0'* ]] || fail "429 did not honor Retry-After"

run_client http_400 65
[[ "$(<"$RUN_OUTPUT")" == *'protocol error: polling request rejected (HTTP 400: test 400)'* ]] || fail "400 protocol error was not surfaced"
run_client http_401 77
[[ "$(<"$RUN_OUTPUT")" == *'authentication error:'* ]] || fail "401 authentication error was not surfaced"
run_client http_403 77
[[ "$(<"$RUN_OUTPUT")" == *'authorization error:'* ]] || fail "403 authorization error was not surfaced"
run_client http_404 65
[[ "$(<"$RUN_OUTPUT")" == *'not-found protocol error:'* ]] || fail "404 not-found error was not surfaced"
run_client malformed 65
malformed_log="$(sed -n 's/^  worker log: //p' "$RUN_OUTPUT" | head -n 1)"
[[ ! -s "$malformed_log" ]] || fail "malformed response partially applied a batch"
[[ "$(<"$RUN_OUTPUT")" == *'protocol error: batch 1 event 1 text must be a string'* ]] || fail "malformed response error was not clear"
run_client unknown_terminal 1
[[ "$(<"$RUN_OUTPUT")" == *'x run custom_terminal_error'* ]] || fail "authoritative unknown terminal status was not displayed"

cancel_output="$TMP/cancel.out"
(cd "$ROOT" && exec env TMPDIR="$TMP" OFFLOAD_CONFIG="$TMP/config" OFFLOAD_API_URL="http://127.0.0.1:$PORT" OFFLOAD_API_KEY=test OFFLOAD_POLL_INTERVAL=1 OFFLOAD_POLL_TIMEOUT=8 ./offload.sh submit cancel) >"$cancel_output" 2>&1 &
CLIENT_PID=$!
for _ in {1..50}; do
  cancel_count="$(python3 -c 'import json, pathlib, sys; print(sum(json.loads(line).get("scenario") == "cancel" for line in pathlib.Path(sys.argv[1]).read_text().splitlines()))' "$REQUESTS")"
  [[ "$cancel_count" -gt 0 ]] && break
  sleep 0.1
done
[[ "${cancel_count:-0}" -gt 0 ]] || fail "cancel scenario never started polling"
kill -TERM "$CLIENT_PID"
set +e
wait "$CLIENT_PID"
cancel_status=$?
set -e
CLIENT_PID=""
[[ "$cancel_status" -eq 130 ]] || fail "cancelled client exited $cancel_status instead of 130"
sleep 1.2
cancel_count_after="$(python3 -c 'import json, pathlib, sys; print(sum(json.loads(line).get("scenario") == "cancel" for line in pathlib.Path(sys.argv[1]).read_text().splitlines()))' "$REQUESTS")"
[[ "$cancel_count_after" -eq "$cancel_count" ]] || fail "polling continued after cancellation"
compgen -G "$TMP/offload-poll-*" >/dev/null && fail "polling state was not cleaned up after cancellation"

python3 - "$REQUESTS" <<'PY'
import json
from pathlib import Path
import sys

records = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
assert not any("old_status_path" in record for record in records), "client used the obsolete status endpoint"
for record in records:
    assert record["limit"] == 262144
    assert record["accept"] == "application/json"
    assert record["authorization"] == "Bearer test"

def scenario(name):
    return [record for record in records if record.get("scenario") == name]

happy = scenario("happy")
assert [record["after"] for record in happy] == [0, 0, 1, 2]
assert happy[1]["time"] - happy[0]["time"] >= 0.8, "caught-up queued response did not wait"
assert happy[2]["time"] - happy[1]["time"] < 0.8, "has_more did not poll immediately"
assert happy[3]["time"] - happy[2]["time"] < 0.8, "terminal has_more did not keep draining"
for name in ("network_retry", "server_retry", "rate_limit"):
    attempts = scenario(name)
    assert [record["after"] for record in attempts] == [0, 0], f"{name} advanced its cursor while retrying"
    assert attempts[1]["time"] - attempts[0]["time"] >= 0.8, f"{name} did not back off"
PY

export OFFLOAD_CONFIG="$TMP/config"
# shellcheck source=../offload.sh
source "$ROOT/offload.sh"
unit_body="$TMP/unit.json"
unit_state="$TMP/unit-state.json"
unit_log="$TMP/unit.log"
python3 - "$unit_body" <<'PY'
import json
from pathlib import Path
import sys

Path(sys.argv[1]).write_text(json.dumps({
    "run": {"run_id": "unit", "status": "running", "terminal": False, "worker_id": "worker", "updated_at": 1.0, "finished_at": None},
    "batches": [{"seq": 1, "events": [{"prompt_index": 0, "text": "same\n"}, {"prompt_index": 1, "text": "other\n"}]}],
    "last_seq": 1,
    "has_more": False,
}))
PY
apply_events_response "$unit_body" unit 0 "$unit_state" "$unit_log" >/dev/null
unit_log_inode="$(stat -f '%i' "$unit_log" 2>/dev/null || stat -c '%i' "$unit_log")"
apply_events_response "$unit_body" unit 0 "$unit_state" "$unit_log" >/dev/null
[[ "$(stat -f '%i' "$unit_log" 2>/dev/null || stat -c '%i' "$unit_log")" == "$unit_log_inode" ]] || fail "live worker log was replaced instead of appended"
[[ "$(grep -c '^\[prompt 0\] same$' "$unit_log")" -eq 1 ]] || fail "same-cursor replay duplicated committed output"
[[ "$(grep -c '^\[prompt 1\] other$' "$unit_log")" -eq 1 ]] || fail "multi-event batch was not applied atomically"

echo "PASS: unified events polling, validation, retries, output safety, and cancellation"
