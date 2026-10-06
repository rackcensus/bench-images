#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"

out=$(mkdir -p "$1" && cd "$1" && pwd)
sysbench_image=$2
mysql_image=$3

verify_setup sysbench
sock_volume="rc-verify-mysql-sock-$$"
volume "$sock_volume"
run_bg rc-verify-mysql -v "$sock_volume:/var/run/mysqld" \
  -e MYSQL_ROOT_PASSWORD=verify -e MYSQL_DATABASE=sbtest -e MYSQL_USER=sbtest -e MYSQL_PASSWORD=sbtest \
  "$mysql_image"

mysql_ready() {
  docker logs rc-verify-mysql 2>&1 | grep 'ready for connections' | grep -q 'port: 3306'
}
wait_for mysql 180 mysql_ready

common=(--db-driver=mysql --mysql-socket=/var/run/mysqld/mysqld.sock --mysql-user=sbtest --mysql-password=sbtest
  --mysql-db=sbtest --tables=2 --table-size=1000)

sb() {
  run_fg -v "$sock_volume:/var/run/mysqld" "$sysbench_image" sysbench "$@"
}

start=$(date +%s.%N)
sb oltp_read_write "${common[@]}" --threads=2 prepare > "$out/sysbench-prepare.txt"
load_seconds=$(python3 -I -c "import sys; print(round($(date +%s.%N) - $start, 2))")

for workload in oltp_read_write oltp_read_only; do
  docker exec rc-verify-mysql mysql -uroot -pverify -e 'RESET BINARY LOGS AND GTIDS' 2> /dev/null
  sb "$workload" "${common[@]}" --threads=2 --time=3 --report-interval=0 --histogram --percentile=99 \
    run > "$out/sysbench-$workload.txt"
  grep -q 'transactions:' "$out/sysbench-$workload.txt" || fail "sysbench $workload printed no transactions"
  grep -q 'Latency histogram' "$out/sysbench-$workload.txt" || fail "sysbench $workload printed no histogram"
  log "sysbench $workload: $(grep 'transactions:' "$out/sysbench-$workload.txt" | xargs)"
done
sb oltp_read_write "${common[@]}" cleanup > /dev/null

version=$(sb --version)
server=$(docker exec rc-verify-mysql mysql -uroot -pverify -Nse 'SELECT VERSION()' 2> /dev/null)
plugin=$(docker exec rc-verify-mysql mysql -uroot -pverify -Nse "SELECT plugin FROM mysql.user WHERE user = 'sbtest'" 2> /dev/null)
python3 -I - "$out" "$version" "$server" "$plugin" "$load_seconds" <<'EOF'
import json, re, sys
out, version, server, plugin, load_seconds = sys.argv[1:]
runs = []
for workload in ("oltp_read_write", "oltp_read_only"):
    text = open(f"{out}/sysbench-{workload}.txt").read()
    transactions = re.search(r"transactions:\s+(\d+)\s+\(([\d.]+) per sec", text)
    count, tps = int(transactions.group(1)), float(transactions.group(2))
    qps = float(re.search(r"queries:\s+(\d+)\s+\(([\d.]+) per sec", text).group(2))
    errors = int(re.search(r"ignored errors:\s+(\d+)", text).group(1))
    reconnects = int(re.search(r"reconnects:\s+(\d+)", text).group(1))
    p99 = float(re.search(r"99th percentile:\s+([\d.]+)", text).group(1))
    if tps <= 0 or reconnects or errors > count * 0.01:
        raise SystemExit(f"sysbench {workload} looks wrong: tps {tps}, errors {errors}, reconnects {reconnects}")
    runs.append({"workload": workload, "tps": tps, "qps": qps, "errors": errors, "reconnects": reconnects, "p99_ms": p99})
json.dump({"tool": "sysbench", "version": version, "server": server, "auth_plugin": plugin,
           "transport": "unix socket", "load_seconds": float(load_seconds), "runs": runs},
          open(f"{out}/sysbench.json", "w"), indent=2)
EOF
log "sysbench ok against mysql $server over a unix socket with $plugin"
