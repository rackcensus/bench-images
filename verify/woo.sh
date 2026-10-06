#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"

out=$(mkdir -p "$1" && cd "$1" && pwd)
app_image=$2
db_image=$3
k6_image=$4
vus=${5:-4}
duration=${6:-15}
cpus=2
workers=4

verify_setup woo
work="$out/woo-work"
rm -rf "$work"
mkdir -p "$work"
cp "$VERIFY_DIR/k6/woo.js" "$work/woo.js"
docker run --rm --entrypoint cat "$app_image" /usr/share/rackcensus/woocommerce.json > "$work/woocommerce.json"
docker run --rm --entrypoint cat "$db_image" /usr/share/rackcensus/woocommerce.json | cmp -s - "$work/woocommerce.json" \
  || fail "woo-app and woo-db were built from different seeds"
printf '{"base": "http://woo", "vus": %d, "duration_seconds": %d}\n' "$vus" "$duration" > "$work/params.json"

db_start=$(date +%s)
run_bg rc-verify-woo-db --network-alias woo-db "$db_image" --innodb-buffer-pool-size=128M --max-connections=100
wait_for woo-db 300 docker exec rc-verify-woo-db healthcheck.sh --connect --innodb_initialized
db_ready_seconds=$(( $(date +%s) - db_start ))
settings=$(docker exec rc-verify-woo-db mariadb -uroot -pwoo -Nse 'SELECT @@innodb_buffer_pool_size DIV 1048576, @@max_connections' | xargs)
[ "$settings" = "128 100" ] || fail "woo-db ignored the run time overrides: $settings"

run_bg rc-verify-woo-app --network-alias woo -e RC_CPUS=$cpus -e RC_WORKERS=$workers "$app_image"
wait_for woo-app 60 docker exec rc-verify-woo-app curl -sf -o /dev/null --resolve woo:80:127.0.0.1 http://woo/
count_processes() {
  docker exec -i rc-verify-woo-app sh -s count < "$VERIFY_DIR/woo-procs.sh" | grep -c "^$1\$" || true
}
children=$(count_processes php-fpm-child)
nginx_workers=$(count_processes nginx-worker)
[ "$children" -eq "$workers" ] || fail "expected $workers php-fpm children, found $children"
[ "$nginx_workers" -eq "$cpus" ] || fail "expected $cpus nginx workers, found $nginx_workers"
log "woo-app runs $children php-fpm children and $nginx_workers nginx workers"

curl_check() {
  local path=$1 expect=$2
  local status
  status=$(docker exec rc-verify-woo-app curl -s -o /tmp/page -w '%{http_code}' --resolve woo:80:127.0.0.1 "http://woo$path")
  docker exec rc-verify-woo-app grep -q "$expect" /tmp/page || fail "$path is missing $expect"
  [ "$status" = 200 ] || fail "$path returned $status"
  log "curl $path: $status, $(docker exec rc-verify-woo-app stat -c %s /tmp/page) bytes"
}
first_product=$(json_get "$work/woocommerce.json" product_paths 0)
first_category=$(json_get "$work/woocommerce.json" category_paths 0)
first_term=$(json_get "$work/woocommerce.json" search_terms 0)
curl_check / wp-block-woocommerce-product-collection
curl_check "$(json_get "$work/woocommerce.json" pages shop)" woocommerce-result-count
curl_check "$first_category" woocommerce-result-count
curl_check "$first_product" single_add_to_cart_button
curl_check "/?s=$first_term&post_type=product" woocommerce-result-count

sample_memory() {
  docker run --rm -i --pid container:rc-verify-woo-app --cap-add SYS_PTRACE --entrypoint sh "$app_image" -s memory \
    < "$VERIFY_DIR/woo-procs.sh"
  echo "cgroup $(docker exec rc-verify-woo-app cat /sys/fs/cgroup/memory.current) 0 0"
}

: > "$out/woo-memory.txt"
(
  sample=0
  while docker inspect rc-verify-woo-app > /dev/null 2>&1 && [ ! -e "$work/k6-done" ]; do
    sample=$((sample + 1))
    sample_memory | sed "s/^/$sample /" >> "$out/woo-memory.txt" || true
    sleep 2
  done
) &
sampler=$!

log "running k6 with $vus vus for ${duration}s per scenario"
status=0
docker run --rm --label "$VERIFY_LABEL" --network "$VERIFY_NET" --user "$(id -u):$(id -g)" -v "$work:/work" \
  "$k6_image" run --quiet /work/woo.js || status=$?
touch "$work/k6-done"
wait "$sampler" || true
[ "$status" -eq 0 ] || fail "k6 failed with status $status"

docker logs rc-verify-woo-app > "$out/woo-app.log" 2>&1 || fail "could not read the woo-app logs"
grep -iE 'php (fatal|warning)|\[(error|crit|alert|emerg)\]|error' "$out/woo-app.log" > "$out/woo-app-errors.txt" || true
[ ! -s "$out/woo-app-errors.txt" ] || fail "woo-app logged errors: $(head -3 "$out/woo-app-errors.txt")"

python3 -I - "$out" "$work" "$workers" "$cpus" "$db_ready_seconds" <<'EOF'
import json, math, sys
from collections import defaultdict
out, work, workers, cpus, db_ready_seconds = sys.argv[1:]
samples = defaultdict(lambda: defaultdict(list))
for line in open(f"{out}/woo-memory.txt"):
    parts = line.split()
    if len(parts) != 5:
        continue
    sample, kind, rss, pss, uss = parts[0], parts[1], *map(int, parts[2:])
    samples[sample][kind].append((rss, pss, uss))
child = [c for s in samples.values() for c in s["php-fpm-child"]]
if not child:
    raise SystemExit("no php-fpm child memory samples")
mb = lambda kb: round(kb / 1024, 1)
base = []
for s in samples.values():
    if s["cgroup"] and s["php-fpm-child"]:
        base.append(s["cgroup"][0][0] / 1024 - sum(c[2] for c in s["php-fpm-child"]))
memory = {
    "workers": int(workers),
    "cpus": int(cpus),
    "samples": len(samples),
    "rss_proc_mb": mb(max(c[0] for c in child)),
    "pss_proc_mb": mb(max(c[1] for c in child)),
    "uss_proc_mb": mb(max(c[2] for c in child)),
    "container_mb": mb(max(s["cgroup"][0][0] / 1024 for s in samples.values() if s["cgroup"])),
    "base_mb": mb(max(base)) if base else None,
}
summary = json.load(open(f"{work}/k6-summary.json"))
woo = json.load(open(f"{work}/woocommerce.json"))
json.dump({"tool": "k6", "db_ready_seconds": int(db_ready_seconds), "memory": memory, "k6": summary,
           "seed": {k: woo[k] for k in ("product_ids", "category_paths", "search_terms", "versions")}},
          open(f"{out}/woo.json", "w"), indent=2)
print(f"php-fpm child memory under load: rss {memory['rss_proc_mb']} MB, pss {memory['pss_proc_mb']} MB, "
      f"private {memory['uss_proc_mb']} MB, container {memory['container_mb']} MB over {memory['samples']} samples")
EOF
log "woocommerce ok"
