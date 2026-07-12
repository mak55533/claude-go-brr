#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
RUN_ID="test-run-123"
PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
SERVER_PID=""
CLIENT_PID=""

cleanup() {
  if [[ -n "$CLIENT_PID" ]]; then
    kill "$CLIENT_PID" 2>/dev/null || true
    wait "$CLIENT_PID" 2>/dev/null || true
  fi
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP" "$ROOT/.git/offload/$RUN_ID.patch" "$ROOT/.git/offload/$RUN_ID.output.txt"
}
trap cleanup EXIT

python3 - "$PORT" "$RUN_ID" <<'PY' &
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import sys
import time

port = int(sys.argv[1])
run_id = sys.argv[2]
polls = 0

class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def send_json(self, data):
        body = json.dumps(data).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path == "/v1/runs":
            self.send_json({"run_id": run_id})
            return
        self.send_error(404)

    def do_GET(self):
        global polls
        if self.path != f"/v1/runs/{run_id}":
            self.send_error(404)
            return
        polls += 1
        if polls == 1:
            self.send_json({"status": "running", "agent_output": "first worker line\n"})
        else:
            time.sleep(2)
            self.send_json({"status": "ok_patch", "agent_output": "first worker line\nsecond worker line\n", "patch": "diff --git a/a b/a\n"})

ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
SERVER_PID=$!

for _ in {1..50}; do
  python3 -c 'import socket, sys; s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=0.1); s.close()' "$PORT" >/dev/null 2>&1 && break
  sleep 0.1
done

client_output="$TMP/client.out"
(cd "$ROOT" && TMPDIR="$TMP" OFFLOAD_CONFIG="$TMP/config" OFFLOAD_API_URL="http://127.0.0.1:$PORT" OFFLOAD_API_KEY=test OFFLOAD_POLL_INTERVAL=1 OFFLOAD_POLL_TIMEOUT=5 ./offload.sh submit "test worker log") >"$client_output" &
CLIENT_PID=$!

for _ in {1..50}; do
  log_file="$(sed -n 's/^  worker log: //p' "$client_output" | tail -n 1)"
  [[ -n "$log_file" && -f "$log_file" && "$(<"$log_file")" == "first worker line" ]] && break
  sleep 0.1
done

[[ -n "$log_file" ]]
[[ -f "$log_file" ]]
[[ "$log_file" == "$TMP"/* ]]
[[ "$(<"$log_file")" == "first worker line" ]]
kill -0 "$CLIENT_PID"

wait "$CLIENT_PID"
CLIENT_PID=""
output="$(<"$client_output")"
[[ "$(<"$log_file")" == $'first worker line\nsecond worker line' ]]
[[ "$output" != *"first worker line"* ]]
[[ "$output" != *"second worker line"* ]]
[[ "$(<"$ROOT/.git/offload/$RUN_ID.output.txt")" == $'first worker line\nsecond worker line' ]]
[[ "$(<"$ROOT/.git/offload/$RUN_ID.patch")" == "diff --git a/a b/a" ]]

echo "PASS: worker output stays in a temporary log file and is not printed inline"
