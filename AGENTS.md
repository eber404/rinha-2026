# Rinha 2026 — Fraud Detection via Vector Search

## Context

Monorepo for Rinha de Backend 2026. Entire hot path in Zig.

## Architecture

```
[Client] -> :9999 (Zig LB) -> /tmp/rinha/api-1.sock (Zig API)
                              /tmp/rinha/api-2.sock (Zig API)
```

- **Load Balancer**: Zig, std.os.linux, TCP:9999 -> UDS round-robin
- **Fraud API**: Zig, UDS HTTP parser + payload parser + quantization + scorer
- **Preprocessing**: Zig, generates index binaries at build time

## Design Principles

- Early return, avoid unnecessary nesting
- UDS between LB and API
- Reference data in read-only mmap binary files
- No heap allocation in the critical scoring loop
- Hot-reload in docker-compose.yml for development

## Repository Structure

```
load-balancer/    # LB Zig (TCP:9999 -> UDS)
                  # - src/main.zig
                  # - nginx.conf (config)
fraud-api/         # API Zig (HTTP + parser + scoring)
                  # - src/*.zig
                  # - vector-index/ (generated at build time)
                  # - scripts/
                  #     pre-processing.sh  # bootstrap: checks/generates index
                  #     vector_indexer.zig # index generation logic
shared/
  sockets/         # UDS socket files (gitignored)
docker-compose.yml
artifacts/          # benchmark/test results
docs/              # plans and notes
```

## Operational Notes

- Health endpoint: `GET /ready`
- Scoring endpoint: `POST /fraud-score`
- Docker dev: `docker-compose up --build`
- Official test: `make benchmark`
- Official result output: `artifacts/rinha-official-result.json`

## Incident Notes (2026-05)

- If `/fraud-score` returns `503` while `/ready` is `200`, verify `fraud-api/src/dataset.zig` path buffers are null-terminated after `std.fmt.bufPrint`; missing `\0` can break `linux.open` and keep scorer uninitialized.
- If HAProxy logs show `be_fraud_api/<NOSRV> ... SC-- 503`, inspect UDS saturation/backlog and backend flapping first.
- If HAProxy logs show many `sH--` with `~30000ms` on `api1`, treat as backend stall/queue saturation under load, not scoring quality issue.

## References

Challenge rules: https://github.com/zanfranceschi/rinha-de-backend-2026
