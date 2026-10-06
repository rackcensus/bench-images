#!/usr/bin/env bash
set -euo pipefail

VERIFY_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUN_FLAGS=(--init --ulimit nofile=200000:200000 --sysctl net.core.somaxconn=65535)

log() {
  echo "$(date -u +%H:%M:%S) $*"
}

fail() {
  log "$*" >&2
  exit 1
}

verify_setup() {
  VERIFY_NAME=$1
  VERIFY_LABEL="rc-verify=$VERIFY_NAME-$$"
  VERIFY_NET="rc-verify-$VERIFY_NAME-$$"
  docker network create --label "$VERIFY_LABEL" "$VERIFY_NET" > /dev/null
  trap verify_cleanup EXIT
}

verify_cleanup() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    for c in $(docker ps -aq --filter "label=$VERIFY_LABEL"); do
      log "last log lines from $(docker inspect -f '{{.Name}}' "$c")"
      docker logs --tail 40 "$c" 2>&1 | sed 's/^/  /' >&2 || true
    done
  fi
  docker ps -aq --filter "label=$VERIFY_LABEL" | xargs -r docker rm -f -v > /dev/null 2>&1 || true
  docker volume ls -q --filter "label=$VERIFY_LABEL" | xargs -r docker volume rm > /dev/null 2>&1 || true
  docker network ls -q --filter "label=$VERIFY_LABEL" | xargs -r docker network rm > /dev/null 2>&1 || true
  exit "$status"
}

run_bg() {
  local name=$1
  shift
  docker run -d --name "$name" --label "$VERIFY_LABEL" --network "$VERIFY_NET" "${RUN_FLAGS[@]}" "$@" > /dev/null
}

run_fg() {
  docker run --rm --label "$VERIFY_LABEL" --network "$VERIFY_NET" --init "$@"
}

volume() {
  docker volume create --label "$VERIFY_LABEL" "$1" > /dev/null
}

wait_for() {
  local what=$1 timeout=$2
  shift 2
  local start
  start=$(date +%s)
  until "$@" > /dev/null 2>&1; do
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
      fail "$what not ready after ${timeout}s"
    fi
    sleep 1
  done
  log "$what ready after $(( $(date +%s) - start ))s"
}

json_get() {
  python3 -I -c 'import json, sys
data = json.load(open(sys.argv[1]))
for key in sys.argv[2:]:
    data = data[int(key)] if isinstance(data, list) else data[key]
print(data if not isinstance(data, (dict, list)) else json.dumps(data))' "$@"
}
