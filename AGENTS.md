# Rinha 2026 — Fraud Detection via Vector Search

## Context

Monorepo for Rinha de Backend 2026.

## Architecture

```
[Client] -> :9999 (C++ LB) -> /tmp/rinha/api-1.sock (Bun API + C++ addon)
                              /tmp/rinha/api-2.sock (Bun API + C++ addon)
```

- **Load Balancer**: C++, TCP:9999 -> UDS round-robin
- **Fraud API**: Bun, UDS HTTP server, JSON parse + vectorization in TS, KNN via C++ shared library (IVF index)
- **Preprocessing**: C++, generates binary dataset and IVF index at build time

## Design Principles

- Hot-reload in docker-compose for development
- Shared mmap binary files for dataset
- No heap allocation in KNN hot path (C++ addon)
- Round-robin LB with zero business logic

## Operational Notes

- Health endpoint: `GET /ready`
- Scoring endpoint: `POST /fraud-score`
- Docker dev: `docker compose up --build`
- Official test: `make benchmark`
