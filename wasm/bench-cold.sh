#!/usr/bin/env bash
set -euo pipefail

SPIN_BIN=${SPIN_BIN:-spin}
IMAGE=${IMAGE:-quicknotes:lab6}
APP_DIR=${APP_DIR:-$(cd "$(dirname "$0")/moscow-time" && pwd)}

wait_for_http() {
  local url=$1
  local attempt
  for attempt in $(seq 1 100); do
    if curl --max-time 1 -fs -o /dev/null "$url"; then
      return 0
    fi
    sleep 0.01
  done
  return 1
}

printf 'runtime,sample,cold_start_ms\n'
for sample in $(seq 1 5); do
  start=$(date +%s%N)
  (cd "$APP_DIR" && exec "$SPIN_BIN" up --listen 127.0.0.1:3000 >/dev/null 2>&1) &
  spin_pid=$!
  if ! wait_for_http http://127.0.0.1:3000/time; then
    kill "$spin_pid" 2>/dev/null || true
    wait "$spin_pid" 2>/dev/null || true
    echo 'Spin did not become healthy' >&2
    exit 1
  fi
  end=$(date +%s%N)
  printf 'spin,%d,%d\n' "$sample" "$(((end-start)/1000000))"
  kill "$spin_pid"
  wait "$spin_pid" 2>/dev/null || true
  sleep 0.2
done

for sample in $(seq 1 5); do
  start=$(date +%s%N)
  container=$(docker run --rm -d --network host "$IMAGE")
  if ! wait_for_http http://127.0.0.1:8080/health; then
    docker stop "$container" >/dev/null 2>&1 || true
    echo 'Docker container did not become healthy' >&2
    exit 1
  fi
  end=$(date +%s%N)
  printf 'docker,%d,%d\n' "$sample" "$(((end-start)/1000000))"
  docker stop "$container" >/dev/null
  sleep 0.2
done
