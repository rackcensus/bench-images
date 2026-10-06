#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"

out=$(mkdir -p "$1" && cd "$1" && pwd)
postgres_image=$2
tfb_postgres_image=$3

verify_setup pgbench
data_volume="rc-verify-pgdata-$$"
volume "$data_volume"
run_bg rc-verify-postgres -v "$data_volume:/var/lib/postgresql" -e POSTGRES_PASSWORD=verify "$postgres_image"
pg_ready() {
  docker logs rc-verify-postgres 2>&1 | grep -q 'PostgreSQL init process complete' \
    && docker exec rc-verify-postgres pg_isready -U postgres -q
}
wait_for postgres 120 pg_ready

pgx() {
  docker exec -u postgres rc-verify-postgres "$@"
}

pgdata=$(pgx sh -c 'echo $PGDATA')
case "$pgdata" in
  /var/lib/postgresql/*) ;;
  *) fail "PGDATA is $pgdata, expected it under the /var/lib/postgresql volume" ;;
esac
pgx pg_test_fsync -s 1 -f /var/lib/postgresql/fsync-test.tmp > "$out/pg_test_fsync.txt"
grep -q 'ops/sec' "$out/pg_test_fsync.txt" || fail "pg_test_fsync printed no results"

start=$(date +%s.%N)
pgx pgbench -i -s 1 -q postgres > "$out/pgbench-init.txt" 2>&1
load_seconds=$(python3 -I -c "import sys; print(round($(date +%s.%N) - $start, 2))")

for workload in read_write select_only; do
  builtin=tpcb-like
  [ "$workload" = select_only ] && builtin=select-only
  pgx rm -rf /tmp/pgb && pgx mkdir -p /tmp/pgb
  pgx pgbench -b "$builtin" -M prepared -c 2 -j 1 -T 3 --log --sampling-rate=0.5 --log-prefix=/tmp/pgb/log postgres \
    > "$out/pgbench-$workload.txt" 2>&1
  lines=$(pgx sh -c 'cat /tmp/pgb/log* | wc -l')
  [ "$lines" -gt 0 ] || fail "pgbench $workload wrote no sampled log lines"
  log "pgbench $workload: $(grep -E '^tps' "$out/pgbench-$workload.txt" | xargs), $lines sampled transactions"
done

run_bg rc-verify-tfb-postgres --network-alias tfb-database "$tfb_postgres_image" postgres \
  -c max_connections=50 -c shared_buffers=32MB -c effective_cache_size=256MB -c work_mem=4MB -c io_workers=1
tfb_ready() {
  docker logs rc-verify-tfb-postgres 2>&1 | grep -q 'PostgreSQL init process complete' \
    && docker exec rc-verify-tfb-postgres pg_isready -U benchmarkdbuser -d hello_world -q
}
wait_for tfb-postgres 120 tfb_ready
tq() {
  docker exec rc-verify-tfb-postgres psql -U benchmarkdbuser -d hello_world -Atc "$1"
}
checks=$(tq "SELECT concat_ws(' ',
  (SELECT count(*) FROM world), (SELECT count(*) FROM \"World\"),
  (SELECT count(*) FROM fortune), (SELECT count(*) FROM \"Fortune\"),
  (SELECT count(*) FROM pg_extension WHERE extname = 'pg_stat_statements'),
  current_setting('max_connections'), current_setting('shared_buffers'), current_setting('io_workers'),
  current_setting('synchronous_commit'), coalesce(nullif(current_setting('shared_preload_libraries'), ''), 'none'))")
log "tfb-postgres: $checks"
[ "$checks" = "10000 10000 12 12 1 50 32MB 1 off none" ] || fail "tfb-postgres schema or settings are off: $checks"
docker run --rm --label "$VERIFY_LABEL" --network "$VERIFY_NET" -e PGPASSWORD=benchmarkdbpass "$tfb_postgres_image" \
  psql -h tfb-database -U benchmarkdbuser -d hello_world -Atc 'SELECT message FROM fortune WHERE id = 12' > "$out/tfb-fortune.txt"
grep -q 'フレームワークのベンチマーク' "$out/tfb-fortune.txt" || fail "tfb-postgres fortune 12 is not the expected utf-8 text"

version=$(pgx pgbench --version)
server=$(pgx postgres --version)
python3 -I - "$out" "$version" "$server" "$load_seconds" "$pgdata" <<'EOF'
import json, re, sys
out, version, server, load_seconds, pgdata = sys.argv[1:]
runs = []
for workload in ("read_write", "select_only"):
    text = open(f"{out}/pgbench-{workload}.txt").read()
    tps = float(re.search(r"tps = ([\d.]+)", text).group(1))
    failed = int(re.search(r"number of failed transactions: (\d+)", text).group(1))
    if tps <= 0 or failed:
        raise SystemExit(f"pgbench {workload} looks wrong: tps {tps}, failed {failed}")
    runs.append({"workload": workload, "tps": tps, "failed_transactions": failed})
fsync = re.findall(r"^\s+(\S.*?)\s+([\d.]+) ops/sec", open(f"{out}/pg_test_fsync.txt").read(), re.M)
json.dump({"tool": "pgbench", "version": version, "server": server, "pgdata": pgdata, "load_seconds": float(load_seconds),
           "fsync_methods": len(fsync), "runs": runs, "tfb_postgres": "ok"},
          open(f"{out}/pgbench.json", "w"), indent=2)
EOF
log "pgbench ok against $server, tfb-postgres schema and -c overrides ok"
