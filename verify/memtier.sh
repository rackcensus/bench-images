#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"

out=$(mkdir -p "$1" && cd "$1" && pwd)
memtier_image=$2
redis_image=$3

verify_setup memtier
run_bg rc-verify-redis --network-alias redis "$redis_image" redis-server --save "" --appendonly no
wait_for redis 60 docker exec rc-verify-redis redis-cli ping

mt() {
  run_fg -v "$out:/out" "$memtier_image" memtier_benchmark --server=redis --port=6379 --protocol=redis \
    --data-size=32 --key-minimum=1 --key-maximum=10000 --hide-histogram "$@"
}

mt --ratio=1:0 --key-pattern=P:P --requests=allkeys --threads=1 --clients=1 > /dev/null 2>&1
keys=$(docker exec rc-verify-redis redis-cli dbsize)
[ "$keys" -eq 10000 ] || fail "prefill wrote $keys keys, expected 10000"
log "prefilled $keys keys"

for ratio in 1:10 1:1; do
  name=memtier-${ratio/:/-}
  mt --ratio="$ratio" --key-pattern=R:R --threads=1 --clients=4 --test-time=3 --distinct-client-seed \
    --json-out-file="/out/$name.json" > /dev/null 2>&1
  log "memtier $ratio: $(json_get "$out/$name.json" 'ALL STATS' Totals Ops/sec) ops/s"
done

version=$(run_fg "$memtier_image" memtier_benchmark --version | head -1)
server=$(docker exec rc-verify-redis redis-cli info server | awk -F: '/^redis_version/ {print $2}' | tr -d '\r')
python3 -I - "$out" "$version" "$server" "$keys" <<'EOF'
import json, sys
out, version, server, keys = sys.argv[1:]
runs = []
for ratio in ("1:10", "1:1"):
    data = json.load(open(f"{out}/memtier-{ratio.replace(':', '-')}.json"))
    totals = data["ALL STATS"]["Totals"]
    ops = float(totals["Ops/sec"])
    if ops <= 0:
        raise SystemExit(f"memtier {ratio} made no requests")
    runs.append({"ratio": ratio, "ops_per_sec": ops, "p99_ms": float(totals["Percentile Latencies"]["p99.00"])})
json.dump({"tool": "memtier_benchmark", "version": version, "server": server, "keys": int(keys), "runs": runs},
          open(f"{out}/memtier.json", "w"), indent=2)
EOF
log "memtier ok against redis $server"
