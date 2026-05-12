# Rinha 2026 - Fraud Detection

Monorepo for Rinha de Backend 2026.

## Stack

- **Load Balancer**: Zig (`load-balancer/src/main.zig`)
- **API**: Zig (`fraud-api/src/*.zig`)
- **Preprocessing**: Zig, runs at container build time

## Structure

```
load-balancer/   # Zig LB (TCP:9999 -> UDS)
                 # - src/main.zig
                 # - nginx.conf
fraud-api/       # Zig API (HTTP + payload + scorer)
                 # - src/*.zig
                 # - vector-index/ (binary index files)
                 # - scripts/pre-processing.sh
shared/
  sockets/       # UDS socket files
docker-compose.yml
artifacts/        # local benchmark/test results
docs/            # plans and notes
```

## Endpoints

- `GET /ready`
- `POST /fraud-score`

## Commands

```bash
# Start local stack (with hot-reload)
docker-compose up --build

# Run official Rinha test
make benchmark
```

## Official test

`make benchmark` does:

1. Clones (or updates) `zanfranceschi/rinha-de-backend-2026` into `.cache/rinha-official`
2. Runs `./run.sh` in the official repository
3. Copies `test/results.json` to `artifacts/rinha-official-result.json`

> `artifacts/rinha-official-result.json` is saved for local inspection and ignored by Git.
