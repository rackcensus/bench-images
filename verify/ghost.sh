#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"

out=$(mkdir -p "$1" && cd "$1" && pwd)
app_image=$2
db_image=$3
k6_image=$4
vus=${5:-4}
duration=${6:-15}

verify_setup ghost
work="$out/ghost-work"
rm -rf "$work"
mkdir -p "$work"
chmod 777 "$work"
cp "$VERIFY_DIR/k6/ghost.js" "$work/ghost.js"
docker run --rm --entrypoint cat "$app_image" /usr/share/rackcensus/ghost.json > "$work/ghost.json"
docker run --rm --entrypoint cat "$db_image" /usr/share/rackcensus/ghost.json | cmp -s - "$work/ghost.json" \
  || fail "ghost-app and ghost-db were built from different seeds"

start=$(date +%s)
run_bg rc-verify-ghost-db --network-alias ghost-db "$db_image"
wait_for ghost-db 300 docker exec rc-verify-ghost-db mysqladmin ping -h 127.0.0.1 -uroot -pghost --silent
posts=$(docker exec rc-verify-ghost-db mysql -h 127.0.0.1 -uroot -pghost -Nse "SELECT COUNT(*) FROM ghost.posts WHERE status = 'published' AND type = 'post'" 2> /dev/null)
[ "$posts" = "$(json_get "$work/ghost.json" counts posts)" ] || fail "ghost-db has $posts published posts, the seed says $(json_get "$work/ghost.json" counts posts)"

run_bg rc-verify-ghost --network-alias ghost "$app_image"
wait_for ghost 120 sh -c '[ "$(docker exec rc-verify-ghost rc-ghost-status /ghost/api/admin/site/)" = 200 ]'
ready_seconds=$(( $(date +%s) - start ))
for path in / "$(json_get "$work/ghost.json" post_paths 0)" "$(json_get "$work/ghost.json" tag_paths 0)" "$(json_get "$work/ghost.json" author_path)" /rss/; do
  status=$(docker exec rc-verify-ghost rc-ghost-status "$path")
  [ "$status" = 200 ] || fail "$path returned $status"
done
log "ghost serves the seeded site after ${ready_seconds}s"

: > "$out/ghost-memory.txt"
(
  sample=0
  while docker inspect rc-verify-ghost > /dev/null 2>&1 && [ ! -e "$work/k6-done" ]; do
    sample=$((sample + 1))
    echo "$sample $(docker exec rc-verify-ghost cat /sys/fs/cgroup/memory.current) $(docker exec rc-verify-ghost-db cat /sys/fs/cgroup/memory.current)" >> "$out/ghost-memory.txt" || true
    sleep 2
  done
) &
sampler=$!

status=0
for scenario in reader staff; do
  log "running k6 $scenario with $vus vus for ${duration}s"
  docker run --rm --label "$VERIFY_LABEL" --network "$VERIFY_NET" --user "$(id -u):$(id -g)" -v "$work:/work" \
    -e RC_BASE_URL=http://ghost:2368 -e RC_ORIGIN=http://ghost -e RC_SCENARIO=$scenario -e RC_VUS=$vus -e RC_DURATION=${duration}s \
    -e RC_SUMMARY_PATH=/work/k6-$scenario.json -e RC_GHOST_DATA_FILE=/work/ghost.json \
    "$k6_image" run --quiet /work/ghost.js || status=$?
  [ "$status" -eq 0 ] || break
done
touch "$work/k6-done"
wait "$sampler" || true
[ "$status" -eq 0 ] || fail "k6 failed with status $status"

python3 -I - "$out" "$work" "$ready_seconds" <<'PY'
import json, sys
out, work, ready_seconds = sys.argv[1:]
levels = {}
for scenario in ("reader", "staff"):
    summary = json.load(open(f"{work}/k6-{scenario}.json"))
    checks = {}
    for check in summary["root_group"]["checks"]:
        counts = checks.setdefault(check["name"], {"passes": 0, "fails": 0})
        counts["passes"] += check["passes"]
        counts["fails"] += check["fails"]
    failed = {name: counts for name, counts in checks.items() if counts["fails"]}
    if failed:
        raise SystemExit(f"{scenario} checks failed: {failed}")
    steps = {name: metric["values"] for name, metric in summary["metrics"].items() if name.startswith("http_req_failed{step:")}
    if not steps:
        raise SystemExit(f"{scenario} has no per-step failure metrics")
    broken = {name: values["passes"] for name, values in steps.items() if values["passes"]}
    if broken:
        raise SystemExit(f"{scenario} had failed requests: {broken}")
    retried = summary["metrics"]["http_req_failed"]["values"]["passes"]
    if retried:
        print(f"{scenario} retried {retried} sign-in requests that ghost answered with a deadlock")
    values = summary["metrics"]["http_reqs"]["values"]
    levels[scenario] = {"requests": values["count"], "requests_per_second": values["rate"], "checks": checks}
samples = [line.split() for line in open(f"{out}/ghost-memory.txt") if len(line.split()) == 3]
if not samples:
    raise SystemExit("no ghost memory samples")
seed = json.load(open(f"{work}/ghost.json"))
memory = {"samples": len(samples), "app_mb": round(max(int(s[1]) for s in samples) / 1048576, 1),
          "database_mb": round(max(int(s[2]) for s in samples) / 1048576, 1)}
json.dump({"tool": "k6", "ready_seconds": int(ready_seconds), "memory": memory, "levels": levels,
           "seed": {key: seed[key] for key in ("dump_sha256", "counts", "versions")}},
          open(f"{out}/ghost.json", "w"), indent=2)
print(f"ghost peaked at {memory['app_mb']} MB with mysql at {memory['database_mb']} MB, readers did {levels['reader']['requests']} requests, "
      f"staff did {levels['staff']['requests']}")
PY
log "ghost ok"
