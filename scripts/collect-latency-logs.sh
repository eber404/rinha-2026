#!/usr/bin/env bash
set -euo pipefail

since=""
if [[ "${1:-}" == "--since" ]]; then
  since="${2:-}"
  if [[ -z "${since}" ]]; then
    echo "missing value for --since" >&2
    exit 1
  fi
fi

ts="$(date +%Y-%m-%d-%H%M%S)"
out_dir="artifacts/latency/${ts}"
mkdir -p "${out_dir}"

log_cmd=(docker logs)
if [[ -n "${since}" ]]; then
  log_cmd+=(--since "${since}")
fi

"${log_cmd[@]}" haproxy > "${out_dir}/haproxy.log" 2>&1 || true
"${log_cmd[@]}" server-1 > "${out_dir}/server-1.log" 2>&1 || true
"${log_cmd[@]}" server-2 > "${out_dir}/server-2.log" 2>&1 || true

ln -sfn "${ts}" "artifacts/latency/latest"
echo "${out_dir}"
