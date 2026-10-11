#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"

out=$(mkdir -p "$1" && cd "$1" && pwd)
app_image=$2
k6_image=$3
vus=${4:-4}
duration=${5:-15}
workers=2
shared_buffers=128MB

verify_setup discourse
work="$out/discourse-work"
rm -rf "$work"
mkdir -p "$work"
chmod 777 "$work"
cp "$VERIFY_DIR/k6/discourse.js" "$work/discourse.js"
docker run --rm --entrypoint cat "$app_image" /usr/share/rackcensus/discourse.json > "$work/discourse.json"

start=$(date +%s)
run_bg rc-verify-discourse --network-alias discourse --shm-size=512m -e RC_WORKERS=$workers -e RC_DB_SHARED_BUFFERS=$shared_buffers "$app_image"
page_status() {
  docker exec rc-verify-discourse curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H 'Host: discourse' "http://127.0.0.1$1"
}
wait_for discourse 600 sh -c "[ \"\$(docker exec rc-verify-discourse curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: discourse' http://127.0.0.1/srv/status)\" = 200 ]"
ready_seconds=$(( $(date +%s) - start ))
topic=$(json_get "$work/discourse.json" topic_path)
[ "$(page_status "$topic")" = 200 ] || fail "$topic didn't answer 200"
[ "$(docker exec rc-verify-discourse su postgres -c 'psql -tA -c "show shared_buffers"')" = "$shared_buffers" ] || fail "discourse ignored RC_DB_SHARED_BUFFERS"
processes=$(docker exec rc-verify-discourse ps -eo args)
if grep -q '^\[rosetta\]' <<< "$processes"; then
  log "running under rosetta, which hides pitchfork's worker titles, so the worker count goes unchecked"
else
  wait_for "$workers app workers" 120 sh -c "[ \"\$(docker exec rc-verify-discourse ps -eo args | grep -c '[w]orker\[')\" = $workers ]"
fi

: > "$out/discourse-memory.txt"
(
  sample=0
  while docker inspect rc-verify-discourse > /dev/null 2>&1 && [ ! -e "$work/k6-done" ]; do
    sample=$((sample + 1))
    echo "$sample $(docker exec rc-verify-discourse cat /sys/fs/cgroup/memory.current)" >> "$out/discourse-memory.txt" || true
    sleep 2
  done
) &
sampler=$!

status=0
for scenario in signed_in anonymous; do
  log "running k6 $scenario with $vus vus for ${duration}s"
  docker run --rm --label "$VERIFY_LABEL" --network "$VERIFY_NET" --user "$(id -u):$(id -g)" -v "$work:/work" \
    -e RC_BASE_URL=http://discourse -e RC_SCENARIO=$scenario -e RC_VUS=$vus -e RC_DURATION=${duration}s \
    -e RC_SUMMARY_PATH=/work/k6-$scenario.json -e RC_DISCOURSE_DATA_FILE=/work/discourse.json \
    "$k6_image" run --quiet /work/discourse.js || status=$?
  [ "$status" -eq 0 ] || break
done
touch "$work/k6-done"
wait "$sampler" || true
[ "$status" -eq 0 ] || fail "k6 failed with status $status"

python3 -I - "$out" "$work" "$workers" "$ready_seconds" <<'EOF'
import json, sys
out, work, workers, ready_seconds = sys.argv[1:]
levels = {}
for scenario in ("signed_in", "anonymous"):
    summary = json.load(open(f"{work}/k6-{scenario}.json"))
    checks = {}
    for check in summary["root_group"]["checks"]:
        counts = checks.setdefault(check["name"], {"passes": 0, "fails": 0})
        counts["passes"] += check["passes"]
        counts["fails"] += check["fails"]
    failed = {name: counts for name, counts in checks.items() if counts["fails"]}
    if failed:
        raise SystemExit(f"{scenario} checks failed: {failed}")
    requests = summary["metrics"]["http_reqs"]["values"]["count"]
    if summary["metrics"]["http_req_failed"]["values"]["rate"] > 0:
        raise SystemExit(f"{scenario} had failed requests")
    levels[scenario] = {"requests": requests, "requests_per_second": summary["metrics"]["http_reqs"]["values"]["rate"], "checks": checks}
samples = [int(line.split()[1]) for line in open(f"{out}/discourse-memory.txt") if len(line.split()) == 2]
if not samples:
    raise SystemExit("no discourse memory samples")
seed = json.load(open(f"{work}/discourse.json"))
memory = {"workers": int(workers), "samples": len(samples), "container_mb": round(max(samples) / 1048576, 1)}
json.dump({"tool": "k6", "ready_seconds": int(ready_seconds), "memory": memory, "levels": levels,
           "seed": {key: seed[key] for key in ("topic_path", "dump_sha256", "versions")}},
          open(f"{out}/discourse.json", "w"), indent=2)
print(f"discourse with {workers} workers peaked at {memory['container_mb']} MB, signed in did {levels['signed_in']['requests']} requests, "
      f"anonymous did {levels['anonymous']['requests']}")
EOF
log "discourse ok"
