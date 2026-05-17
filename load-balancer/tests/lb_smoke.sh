#!/usr/bin/env bash
set -euo pipefail

URL="http://localhost:9999/ready"
code=$(curl -sS -o /tmp/lb_ready_body.txt -w "%{http_code}" "$URL" || true)

if [[ "$code" != "200" ]]; then
  echo "FAIL: expected 200 from $URL, got $code"
  if [[ -f /tmp/lb_ready_body.txt ]]; then
    echo "Body:"
    cat /tmp/lb_ready_body.txt
  fi
  exit 1
fi

echo "PASS: /ready returned 200"
