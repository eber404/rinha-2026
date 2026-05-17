# Rinha 2026 Benchmark Optimization

## Charter

**Original request**: Execute and optimize the E2E benchmark for this fraud detection repository, targeting `http_errors=0`, `failure_rate=0`, `p99<5ms`.

**Interpreted outcome**: Make the benchmark pass by reducing HTTP errors and latency under k6 load (900 RPS, 250 VUs).

**Input shape**: `recovery` — the system works for single requests but fails under load.

**Non-goals**: Don't relax benchmark criteria; don't alter business logic; don't remove validations.

**Constraints**:
- `http_errors = 0`
- `failure_rate = 0`
- `p99 < 5ms`
- Must use Docker Compose + Makefile
- Cannot change benchmark scoring rules

**Authority**: `requested`

**Proof type**: `metric` — benchmark results.json output

**Completion proof**: `make benchmark` shows http_errors=0, failure_rate=0, p99<5ms

**Likely misfire**: Fixing only the error rate while p99 still hits the 2001ms timeout cutoff (cut_triggered=true in results).

**Blind spots**:
- Whether the 5ms p99 target is achievable given 3M dataset and CPU limits
- Whether the LB or the API is the bottleneck under load
- Memory pressure from mmap'd 168MB dataset within 128MB container limit

**Existing plan facts**:
- k6 runs at 900 RPS with 250 max VUs for 120s
- Each API container limited to 0.35 CPU and 128MB RAM
- LB uses round-robin over 2 API sockets
- C++ KNN engine does IVF search with 512 clusters, KNN_NPROBE

## Board Shape

1. **T001 (Scout)**: Map the system under load — identify where connections drop and why
2. **T002 (Judge)**: Prioritize fixes by impact and feasibility
3. **T003+ (Worker)**: Execute bounded fixes
4. **T999 (Judge)**: Final audit