# Rinha 2026 — Fraud Detection via Vector Search

## Context

This is a monorepo for the **Rinha de Backend 2026** challenge: building a fraud detection module for credit card transactions using vector search.

## Architecture

```
[Client] → :9999 (Zig LB, round-robin) → /tmp/rinha/api-1.sock (Bun API)
                                              /tmp/rinha/api-2.sock (Bun API)
```

- **Load Balancer**: Zig, pure std.linux, TCP:9999 → UDS
- **Fraud API**: Bun, UDS listener, vector search, KNN classification

## Design Principles

- Clean code: early returns, no nested ifs, no coupling
- Unix domain sockets for low-latency internal communication
- Binary format for reference index (fast mmap access)
- Minimal dependencies (Zig std only, Bun built-ins)

## Repository Structure

```
load-balancer/    # Zig LB (TCP proxy → UDS)
fraud-api/        # Bun API (UDS + vector search)
build/            # Data download + conversion scripts
docker-compose.yml
```

## Key Decisions

| Aspect | Choice |
|--------|--------|
| LB→API comms | UDS (lower latency than TCP) |
| Vector index | Binary file (mmap-friendly) |
| Search | Linear scan KNN (simple, works for 3M records) |
| Normalization | Per-dimension with constants from normalization.json |

## Quality

- Unit tests for both Zig and Bun modules
- Docker-based integration-ready setup

## References

Challenge rules: https://github.com/zanfranceschi/rinha-de-backend-2026