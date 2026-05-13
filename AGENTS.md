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

## Performance Experiments (2026-05-13)

### Worktree
All perf experiments run in isolated worktree `.worktrees/fraud-engine-lab` on branch `perf/fraud-engine-lab`.

### Results Summary

| Experiment | ns/op | vs Baseline | Status |
|------------|-------|-------------|--------|
| Baseline (H0) | 25458 | — | committed |
| H1 SIMD distance | 11701 | -54% | committed |
| H4 Centroid no-copy | 10658 | -58.1% | committed |
| H5 TopK branchless | 9365 | -63.2% | committed |
| H6 Prefetch | 9124 | -64.2% | committed |
| H7 Graduated bias | 11762 | +23% | **rejected** |
| H8 Inline SIMD | 8964 | -1.8% | accepted |
| **H9 Two-pass scan** | **5951** | **-76%** | **accepted** |

### Key Findings

- **H9 two-pass cluster scan is the winner** — 36% improvement over H8, 76% over baseline
- H7 (graduated bias static allocation) made things worse — clusters 0-1 receiving more budget caused over-scanning
- H8 (inline SIMD) gave marginal 1.8% improvement but was accepted at user discretion
- H6 (prefetch) provides consistent baseline but H9 overtakes it significantly

### Scoring Hot Path (scorer.zig)

The `score()` function in `fraud-engine/src/scorer.zig` is the critical path:

1. `findNearestClusters` — SIMD centroid scan, finds top-NPROBE clusters (NPROBE=8)
2. Two-pass scan:
   - **Pass1** (60% budget): uniform split across all 8 clusters, tracks `cluster_contrib[]` (vectors inserted in top_k per cluster)
   - **Pass2** (40% budget): weighted redistribution to top-2 contributing clusters
3. Inline SIMD distance computation via `@Vector(16, i8/i16/i32)` + `@reduce(.Add, sq)`
4. TopK insert with sorted insert-sort, early reject if dist >= worst
5. Optional fallback if top_k.count < K (scans entire dataset)

### Perf Testing

```bash
cd .worktrees/fraud-engine-lab
make perfloop PERF_MAX_NS=9412 PERF_ITERS=200 PERF_WARMUP_ITERS=50
```

Perf gate: pass if mean drop ≥8% vs baseline and no run exceeds baseline_worst + 5%.
Runner uses Docker `zig test` with `RUN_PERF_TESTS=1` env var.

### Constants (scorer.zig)

```zig
pub const K: u32 = 5;                    // top-k candidates
pub const NPROBE: u32 = 8;               // clusters to scan
pub const TOTAL_SCAN_BUDGET: u32 = 28_000; // vectors per scoring call
```

## References

Challenge rules: https://github.com/zanfranceschi/rinha-de-backend-2026