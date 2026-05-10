# Rinha 2026 - Fraud Detection

Monorepo for Rinha de Backend 2026.

## Stack

- **Load Balancer**: Zig (`load-balancer/src/main.zig`)
- **API**: Zig (`fraud-api/src/*.zig`)
- **Preprocess**: Bun (`preprocess/src/generate_index.bun`)
- **Dataset**: binaries in `data/*.bin`

## Structure

```
load-balancer/   # Zig LB (TCP:9999 -> UDS)
fraud-api/       # Zig API (HTTP + payload + scorer)
preprocess/      # Index and binary generation
docs/            # plans and notes
artifacts/       # local benchmark/test results
```

## Endpoints

- `GET /ready`
- `POST /fraud-score`

## Commands

```bash
# Start local stack
docker-compose up -d --build

# Run official Rinha test and save result
make test-official
```

## Official test

`make test-official` does:
1. Clones (or updates) `zanfranceschi/rinha-de-backend-2026` into `.cache/rinha-official`
2. Runs `./run.sh` in the official repository
3. Copies `test/results.json` to `artifacts/rinha-official-result.json`

> `artifacts/rinha-official-result.json` is saved for local inspection and ignored by Git.
