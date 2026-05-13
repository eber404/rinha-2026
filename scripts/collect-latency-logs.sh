#!/usr/bin/env bash
set -euo pipefail

ts="$(date +%Y-%m-%d-%H%M%S)"
out_dir="artifacts/latency/${ts}"
mkdir -p "${out_dir}"

docker logs haproxy > "${out_dir}/haproxy.log" 2>&1 || true
docker logs server-1 > "${out_dir}/server-1.log" 2>&1 || true
docker logs server-2 > "${out_dir}/server-2.log" 2>&1 || true

ln -sfn "${ts}" "artifacts/latency/latest"
echo "${out_dir}"
