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
- **Preprocess**: Bun, generates index binaries

## Design Principles

- Early return, avoid unnecessary nesting
- UDS between LB and API
- Reference data in read-only mmap binary files
- No heap allocation in the critical scoring loop
- Hot-reload in docker-compose.yml for development

## Repository Structure

```
load-balancer/    # LB Zig (TCP -> UDS)
fraud-api/         # API Zig (HTTP + parser + scoring)
preprocess/        # Bun scripts to generate index files
shared/
  build/           # scripts to download/convert reference data
  sockets/         # UDS socket files
docker-compose.yml
```

## Operational Notes

- Health endpoint: `GET /ready`
- Scoring endpoint: `POST /fraud-score`
- Run preprocess: `bun run src/generate_index.bun` (inside preprocess/)
- Official test: `make test-official`
- Official result output: `artifacts/rinha-official-result.json`

## References

Challenge rules: https://github.com/zanfranceschi/rinha-de-backend-2026