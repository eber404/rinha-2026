# E2E Latency Tracing Design (HAProxy + Go + Zig)

## Goal

Add end-to-end latency tracing with per-module and inter-module timing so we can identify current p99 bottleneck with one benchmark run.

## Scope

- Add request correlation ID across HAProxy and Go API.
- Emit per-request phase timings in Go (`read`, `parse`, `eval`, `response`, `total`).
- Emit HAProxy timing tuple (`Tq`, `Tw`, `Tc`, `Tr`, `Tt`) with request ID.
- Collect logs from one benchmark run.
- Generate markdown report with p50/p95/p99 and bottleneck conclusion.

## Non-Goals

- No scoring logic changes.
- No ranking optimization in this step.
- No multi-run statistical confidence loop.

## Recommended Approach

Correlation-ID + structured logs.

1. HAProxy injects request ID header (`X-Req-Id`) and logs timing fields with that ID.
2. Go reads `X-Req-Id` and logs JSON per request with phase timings.
3. Analysis script joins HAProxy and Go records by `req_id`.
4. Script outputs markdown report in `docs/plans/`.

## Alternatives Considered

1. Window-level aggregates only (existing 5s logs)
   - Too coarse for p99 tail root cause.

2. pprof-only profiling
   - Good for CPU internals, weak for inter-component queue/wait attribution.

## Data Model

### HAProxy per request

- `req_id`
- `backend`, `server`
- `status`
- `Tq`, `Tw`, `Tc`, `Tr`, `Tt` (ms)

### Go per request

- `req_id`, `instance`, `status`
- `t_read_us`
- `t_parse_us`
- `t_eval_us`
- `t_resp_us`
- `t_total_us`
- `parse_err`, `eval_err`, `mock_mode`

## Derived Metrics (Report)

- Per module p50/p95/p99:
  - LB queue/wait (`max(Tq, Tw)`)
  - LB upstream roundtrip (`Tr`)
  - Go read/parse/eval/resp/total
- Inter-module estimates:
  - `lb_front_overhead ~= Tt - Tr - Tc`
  - `network_handoff ~= Tr - (t_total_us/1000)`

## Bottleneck Decision Rules

- If `p99(max(Tq,Tw))` dominates: bottleneck = LB/queueing/scheduling.
- If `p99(t_eval_us)` dominates: bottleneck = Zig scorer.
- If `p99(t_parse_us)` dominates: bottleneck = Go parse.
- If `Tr >> t_total_us/1000`: bottleneck = transport/backpressure path.

## Execution Plan (Single Run)

1. Deploy tracing changes.
2. Run one official benchmark.
3. Collect logs to `artifacts/latency/`.
4. Run analysis script.
5. Save report markdown with tables and conclusion.

## Output Format

Markdown report in `docs/plans/` containing:

- Test context (resources, commit, benchmark artifact)
- Percentile tables per module
- Inter-module latency table
- Top tail samples
- Final bottleneck conclusion and next actions
