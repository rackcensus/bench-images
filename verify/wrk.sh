#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"

out=$(mkdir -p "$1" && cd "$1" && pwd)
wrk_image=$2
server_image=$3

verify_setup wrk
run_bg rc-verify-http --network-alias tfb-server "$server_image"
wait_for "http server" 30 run_fg "$wrk_image" curl -sf -o /dev/null http://tfb-server/

run_fg "$wrk_image" wrk -H 'Host: tfb-server' -H 'Accept: text/html' -H 'Connection: keep-alive' \
  --latency -d 3 -c 8 --timeout 8 -t 1 http://tfb-server:80/ | tee "$out/wrk.txt"

rps=$(awk '/^Requests\/sec:/ {print $2}' "$out/wrk.txt")
requests=$(awk '/requests in/ {print $1}' "$out/wrk.txt")
grep -q '^  Latency Distribution' "$out/wrk.txt" || fail "wrk output has no latency distribution"
grep -q '99%' "$out/wrk.txt" || fail "wrk output has no p99"
if grep -qE 'Socket errors|Non-2xx' "$out/wrk.txt"; then
  fail "wrk reported socket errors or non-2xx responses"
fi
[ -n "$rps" ] && [ "${requests:-0}" -gt 0 ] || fail "wrk made no requests"
version=$(run_fg "$wrk_image" wrk -v 2>&1 | head -1 || true)

python3 -I - "$out/wrk.json" "$rps" "$requests" "$version" <<'EOF'
import json, sys
path, rps, requests, version = sys.argv[1:]
json.dump({"tool": "wrk", "version": version.strip(), "requests": int(requests), "requests_per_second": float(rps)}, open(path, "w"), indent=2)
EOF
log "wrk ok: $requests requests at $rps req/s"
