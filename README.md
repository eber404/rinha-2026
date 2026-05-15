# Rinha 2026 — Fraud Detection via Vector Search

Monorepo for Rinha de Backend 2026.

## Stack

- **Load Balancer**: C++ (`load-balancer/src/main.cpp`) — TCP:9999 → UDS round-robin
- **Fraud API**: Bun (`fraud-api/src/index.ts`) — HTTP/UDS + JSON parse + vectorize + C++ IVF KNN addon
- **Preprocessing**: C++ (`scripts/preprocess.cpp`) — generates binary dataset + IVF index at build time

## Structure

```
load-balancer/   # C++ LB (TCP:9999 -> UDS)
                 # - src/main.cpp
                 # - Dockerfile
fraud-api/       # Bun API (HTTP + parser + scoring)
                 # - src/index.ts
                 # - src/vectorize.ts
                 # - native/knn.cpp knn.h binding.cpp
                 # - package.json
scripts/         # Preprocessing and dataset reduction
                 # - preprocess.cpp
                 # - reduce_dataset.cpp
                 # - preprocess.sh
vector-index/    # Generated binary files (gitignored)
docker-compose.yml
Makefile
```

## Endpoints

- `GET /ready`
- `POST /fraud-score`

## Commands

```bash
# Start local stack (with hot-reload)
docker compose up --build

# Run official Rinha test
make benchmark
```

## Official test

`make benchmark` runs the official test engine from `.cache/rinha-official/run.sh`. Ensure the official repo is already cloned there.
