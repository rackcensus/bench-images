#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"

out=$(mkdir -p "$1" && cd "$1" && pwd)
app_image=$2
db_image=$3
redis_image=$4
k6_image=$5
vus=${6:-4}
duration=${7:-15}

verify_setup wagtail
work="$out/wagtail-work"
rm -rf "$work"
mkdir -p "$work"
chmod 777 "$work"
cp "$VERIFY_DIR/k6/wagtail.js" "$work/wagtail.js"
docker run --rm --entrypoint cat "$app_image" /usr/share/rackcensus/wagtail.json > "$work/wagtail.json"
docker run --rm --entrypoint cat "$db_image" /usr/share/rackcensus/wagtail.json | cmp -s - "$work/wagtail.json" \
  || fail "wagtail-app and wagtail-db were built from different seeds"

start=$(date +%s)
run_bg rc-verify-wagtail-db --network-alias wagtail-db "$db_image"
run_bg rc-verify-wagtail-redis --network-alias wagtail-redis "$redis_image"
wait_for wagtail-db 300 docker exec rc-verify-wagtail-db pg_isready -h 127.0.0.1 -U app_user -d app_db -q
wait_for wagtail-redis 60 sh -c '[ "$(docker exec rc-verify-wagtail-redis redis-cli ping)" = PONG ]'
pages=$(docker exec rc-verify-wagtail-db psql -h 127.0.0.1 -U app_user -d app_db -tAc "SELECT COUNT(*) FROM wagtailcore_page WHERE live AND depth > 1")
[ "$pages" -ge "$(json_get "$work/wagtail.json" counts pages)" ] || fail "wagtail-db has $pages live pages, the seed says $(json_get "$work/wagtail.json" counts pages)"

run_bg rc-verify-wagtail --network-alias wagtail "$app_image"
wait_for wagtail 120 sh -c '[ "$(docker exec rc-verify-wagtail rc-wagtail-status /)" = 200 ]'
ready_seconds=$(( $(date +%s) - start ))
workers=$(docker exec rc-verify-wagtail ps -eo args | grep -c '^uwsgi /code/etc/uwsgi.ini' || true)
[ "$workers" -eq 3 ] || fail "expected a uwsgi master and 2 workers, found $workers uwsgi processes"
for path in / "$(json_get "$work/wagtail.json" blog_index_path)" "$(json_get "$work/wagtail.json" blog_paths 0)" \
    "$(json_get "$work/wagtail.json" bread_paths 0)" "$(json_get "$work/wagtail.json" location_paths 0)" "/search/?q=bread" /admin/login/; do
  status=$(docker exec rc-verify-wagtail rc-wagtail-status "$path")
  [ "$status" = 200 ] || fail "$path returned $status"
done
log "wagtail serves the seeded site after ${ready_seconds}s"

: > "$out/wagtail-memory.txt"
(
  sample=0
  while docker inspect rc-verify-wagtail > /dev/null 2>&1 && [ ! -e "$work/k6-done" ]; do
    sample=$((sample + 1))
    echo "$sample $(docker exec rc-verify-wagtail cat /sys/fs/cgroup/memory.current) $(docker exec rc-verify-wagtail-db cat /sys/fs/cgroup/memory.current) $(docker exec rc-verify-wagtail-redis cat /sys/fs/cgroup/memory.current)" >> "$out/wagtail-memory.txt" || true
    sleep 2
  done
) &
sampler=$!

status=0
for scenario in visitor editor; do
  log "running k6 $scenario with $vus vus for ${duration}s"
  docker run --rm --label "$VERIFY_LABEL" --network "$VERIFY_NET" --user "$(id -u):$(id -g)" -v "$work:/work" \
    -e RC_BASE_URL=http://wagtail:8000 -e RC_SCENARIO=$scenario -e RC_VUS=$vus -e RC_DURATION=${duration}s \
    -e RC_SUMMARY_PATH=/work/k6-$scenario.json -e RC_WAGTAIL_DATA_FILE=/work/wagtail.json \
    "$k6_image" run --quiet /work/wagtail.js || status=$?
  [ "$status" -eq 0 ] || break
done
touch "$work/k6-done"
wait "$sampler" || true
[ "$status" -eq 0 ] || fail "k6 failed with status $status"

python3 -I - "$out" "$work" "$ready_seconds" <<'PY'
import json, sys
out, work, ready_seconds = sys.argv[1:]
levels = {}
for scenario in ("visitor", "editor"):
    summary = json.load(open(f"{work}/k6-{scenario}.json"))
    checks = {}
    for check in summary["root_group"]["checks"]:
        counts = checks.setdefault(check["name"], {"passes": 0, "fails": 0})
        counts["passes"] += check["passes"]
        counts["fails"] += check["fails"]
    failed = {name: counts for name, counts in checks.items() if counts["fails"]}
    if failed:
        raise SystemExit(f"{scenario} checks failed: {failed}")
    if summary["metrics"]["http_req_failed"]["values"]["rate"] > 0:
        raise SystemExit(f"{scenario} had failed requests")
    values = summary["metrics"]["http_reqs"]["values"]
    levels[scenario] = {"requests": values["count"], "requests_per_second": values["rate"], "checks": checks}
samples = [line.split() for line in open(f"{out}/wagtail-memory.txt") if len(line.split()) == 4]
if not samples:
    raise SystemExit("no wagtail memory samples")
seed = json.load(open(f"{work}/wagtail.json"))
memory = {"samples": len(samples)}
for index, role in ((1, "app_mb"), (2, "database_mb"), (3, "cache_mb")):
    memory[role] = round(max(int(s[index]) for s in samples) / 1048576, 1)
json.dump({"tool": "k6", "ready_seconds": int(ready_seconds), "memory": memory, "levels": levels,
           "seed": {key: seed[key] for key in ("dump_sha256", "counts", "versions")}},
          open(f"{out}/wagtail.json", "w"), indent=2)
print(f"wagtail peaked at {memory['app_mb']} MB with postgres at {memory['database_mb']} MB and redis at {memory['cache_mb']} MB, "
      f"visitors did {levels['visitor']['requests']} requests, editors did {levels['editor']['requests']}")
PY
log "wagtail ok"
