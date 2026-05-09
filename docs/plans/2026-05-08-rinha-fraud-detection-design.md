# Rinha 2026 — Fraud Detection via Vector Search

## Overview

Monorepo with:
- **Load Balancer**: Pure Zig (std.linux), round-robin
- **API**: Pure Bun, vector search with binary index
- **Port**: 9999

## Architecture

```
[ client ] → :9999 (LB Zig, round-robin) → /tmp/rinha/api-1.sock (Bun API)
                                                /tmp/rinha/api-2.sock (Bun API)
```

## Components

### 1. Load Balancer (Zig)
- Listens on port 9999
- Round-robin among N instances
- Pure proxy — no fraud logic
- Uses std.linux (no external dependencies)

### 2. Fraud Detection API (Bun)
Endpoints:
- `GET /ready` → 200 OK
- `POST /fraud-score` → `{ approved: bool, fraud_score: number }`

Flow:
1. Parse payload
2. Normalize to 14D vector (REGRAS_DE_DETECCAO.md)
3. Search 5 nearest neighbors in binary index
4. fraud_score = fraud_count / 5
5. approved = fraud_score < 0.6

### 3. Build Script
- Downloads `references.json.gz`, `normalization.json`, `mcc_risk.json`
- Converts to optimized binary format (`refs.bin`)
- Generates `normalization.json` and `mcc_risk.json` as-is

## Infrastructure

- **docker-compose.yml** with 1 lb + 2 API replicas
- Total limit: 1 CPU, 350MB RAM
- Network: bridge
- Images: public linux-amd64

## Data

- `references.json.gz` → 3M labeled vectors (fraud/legit)
- `normalization.json` → normalization constants
- `mcc_risk.json` → risk by merchant category

## Scoring

- Latency p99: each 10x improvement = +1000 (max +3000)
- Detection: weighted false positive/negative/HTTP error
- Total: -6000 to +6000

## Stack

| Component | Technology | Libraries |
|-----------|------------|-----------|
| Load Balancer | Zig 0.16 | std.linux (pure) |
| API | Bun | Built-in only |
| Vector Search | Bun | Binary mmap index |
| Container | Docker | docker-compose |

## Roadmap

1. Build script (download + generate binary index)
2. Load Balancer in Zig
3. API in Bun
4. docker-compose.yml
5. Local tests