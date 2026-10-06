#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"

out=$(mkdir -p "$1" && cd "$1" && pwd)
refs=$2
only=${3:-wrk,sysbench,memtier,pgbench,woo}
http_server=docker.io/library/nginx:1.30.5-alpine@sha256:0985e772fb9f729e6fa0980da05fca5d9c468e870eed43071545afa9d2e27d94

ref() {
  json_get "$refs" "$1"
}

if ref http-server > /dev/null 2>&1; then
  http_server=$(ref http-server)
fi

mkdir -p "$out"
for check in ${only//,/ }; do
  log "verifying $check"
  case "$check" in
    wrk) "$VERIFY_DIR/wrk.sh" "$out" "$(ref wrk)" "$http_server" ;;
    sysbench) "$VERIFY_DIR/sysbench.sh" "$out" "$(ref sysbench)" "$(ref mysql)" ;;
    memtier) "$VERIFY_DIR/memtier.sh" "$out" "$(ref memtier)" "$(ref redis)" ;;
    pgbench) "$VERIFY_DIR/pgbench.sh" "$out" "$(ref postgres)" "$(ref tfb-postgres)" ;;
    woo) "$VERIFY_DIR/woo.sh" "$out" "$(ref woo-app)" "$(ref woo-db)" "$(ref k6)" ;;
    *) fail "unknown check $check" ;;
  esac
  [ -s "$out/$check.json" ] || fail "$check finished without writing $check.json"
done
log "all checks passed: $only"
