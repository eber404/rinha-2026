# Rinha 2026 — Fraud Detection Cascade + Vector Fallback

## Context

Monorepo for Rinha de Backend 2026.

## Architecture

```
[Client] -> :9999 (C++ LB) -> /tmp/rinha/api-1.sock (Bun API + C++ addon)
                              /tmp/rinha/api-2.sock (Bun API + C++ addon)
```

- **Load Balancer**: C++, TCP:9999 -> UDS round-robin
- **Fraud API**: Bun, UDS HTTP server, JSON parse + vectorization in TS, scoring via C++ shared library (`fraud_*` C ABI)
- **Native scoring engine**: conservative rules/tree first; ambiguous cases fall back to vector search (IVF/KNN)
- **Preprocessing**: C++, generates binary dataset, labels, IVF index, manifest, and conservative rules model

## Design Principles

- Hot-reload in docker-compose for development
- Shared mmap binary files for dataset and labels
- No heap allocation or file I/O in request hot path (C++ addon)
- Round-robin LB with zero business logic
- Correctness first: prefer `AMBIGUOUS -> vector fallback` over risky direct classification
- GBDT is deferred unless benchmark proves no `failure_rate` regression

## Current Fraud Flow

```
payload
  -> TS vectorize[14] (official normalization, preserve -1 sentinels)
  -> C++ ConservativeRules / safe leaves
  -> CLEAR_LEGIT | CLEAR_FRAUD | AMBIGUOUS
  -> AMBIGUOUS uses vector fallback over global index
```

- Public native ABI only:
  - `int fraud_init(const char* dataset_path)`
  - `float fraud_score(const float* vector14)`
  - `void fraud_close()`
- `rules_model.bin` can contain mined safe leaves; runtime consumes serialized rules.
- `manifest.bin` owns runtime config (`dims`, `k_default`, version).
- Direct rules must be conservative and benchmark-validated; never relax to hide errors.

## Operational Notes

- Health endpoint: `GET /ready`
- Scoring endpoint: `POST /fraud-score`
- Docker dev: `docker compose up --build`
- Official test: `make benchmark`
- Native smoke: `make test-native`
- Bun tests (inside container if host lacks Bun): `docker compose exec -T api-1 bun test src/vectorize.test.ts`
