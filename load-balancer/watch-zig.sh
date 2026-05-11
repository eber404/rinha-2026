#!/bin/sh
echo $$ > /tmp/main.pid
watchexec -r -w /app/src -e zig -- \
  "zig build-exe main.zig -O ReleaseSmall -target aarch64-linux-musl -lc && kill -HUP $(cat /tmp/main.pid)"