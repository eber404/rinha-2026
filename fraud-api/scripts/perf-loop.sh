#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

PERF_MAX_NS="${PERF_MAX_NS:-3500}"
PERF_ITERS="${PERF_ITERS:-20000}"
PERF_WARMUP_ITERS="${PERF_WARMUP_ITERS:-5000}"
PERF_LOOP_SLEEP_SECONDS="${PERF_LOOP_SLEEP_SECONDS:-0}"
PERF_DATA_DIR="${PERF_DATA_DIR:-$ROOT_DIR/fraud-engine/vector-index}"

attempt=1

if [ "$(uname -s)" != "Linux" ]; then
  echo "This loop requires Linux (dataset loader uses linux syscalls)."
  exit 2
fi

echo "Starting score() performance loop"
echo "Target: PERF_MAX_NS=$PERF_MAX_NS"
echo "Config: PERF_ITERS=$PERF_ITERS PERF_WARMUP_ITERS=$PERF_WARMUP_ITERS"
echo "Data dir: $PERF_DATA_DIR"

while true; do
  echo "Attempt #$attempt"
  if RUN_PERF_TESTS=1 \
    PERF_MAX_NS="$PERF_MAX_NS" \
    PERF_ITERS="$PERF_ITERS" \
    PERF_WARMUP_ITERS="$PERF_WARMUP_ITERS" \
    PERF_DATA_DIR="$PERF_DATA_DIR" \
    zig test "$ROOT_DIR/fraud-engine/src/scorer.zig" -O ReleaseFast; then
    echo "Performance target reached on attempt #$attempt"
    break
  fi

  attempt=$((attempt + 1))
  if [ "$PERF_LOOP_SLEEP_SECONDS" != "0" ]; then
    sleep "$PERF_LOOP_SLEEP_SECONDS"
  fi
done
