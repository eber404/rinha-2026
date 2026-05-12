# Go Mock Mode for p99 Isolation

## Goal

Measure latency floor of current stack (HAProxy + Go server over UDS) without Zig scoring cost, so p99 bottleneck source becomes clear.

## Scope

- Add temporary mock mode to Go server fraud endpoint.
- Keep request parsing path active.
- Return fixed response payload in mock mode.
- Keep deployment topology identical (2x server + HAProxy + UDS).
- Do not change fraud-engine code.

## Non-Goals

- No scoring quality evaluation in mock runs.
- No permanent API contract change.
- No architectural replacement of scorer path.

## Proposed Approach (Recommended)

Runtime flag via environment variable.

- Add `MOCK_MODE=fixed` support in `server/cmd/server/main.go`.
- In mock mode:
  - skip `zigcore.Init` and `zigcore.Shutdown`
  - set app readiness to true
  - in `POST /fraud-score`, parse request then return fixed JSON response
- In normal mode: keep current behavior unchanged.

Why this approach:

- Minimal code diff.
- Fast on/off toggle in compose.
- Preserves benchmark comparability (same infra and network path).

## Alternative Approaches Considered

1. Build tags for separate mock binary
   - Pros: zero runtime branch
   - Cons: more build/deploy complexity

2. Separate mock service/container
   - Pros: complete test isolation
   - Cons: diverges from production-like topology

## Data Flow

### Normal mode

`request -> read body -> payload.Parse -> zigcore.Eval -> response`

### Mock fixed mode

`request -> read body -> payload.Parse -> fixed response`

Fixed body:

`{"approved":true,"fraud_score":0.01,"instance":"<id>"}`

## Error Handling

- Keep current status behavior for request validation:
  - non-POST on `/fraud-score`: `405`
  - body read failure: `400`
  - payload parse failure: `400`
- In mock mode, no `503` from scoring path.
- `/ready` should return healthy in mock mode.

## Observability Expectations

- `status200/400/405` counters remain meaningful.
- `avg_ms_eval` approaches zero in mock mode.
- `zig_*` counters remain zero in mock mode.
- End-to-end p99 delta vs baseline estimates scorer contribution.

## Benchmark Protocol

1. Enable mock mode in both server instances.
2. Run official benchmark 3 times.
3. Collect `p99`, `final_score`, `http_errors`.
4. Compare mock `p99` against current real-score `p99` baseline.

Interpretation:

- If p99 drops sharply: scorer still dominant.
- If p99 stays high: bottleneck outside Zig core (Go HTTP/parse, UDS, HAProxy, scheduling, container limits).

## Rollback

- Remove or unset `MOCK_MODE`.
- Normal scorer path resumes without code rollback.

## Risks

- Benchmark final score becomes non-comparable for ranking (expected).
- Mock result can be misread as product performance (must label as diagnostic run).

## Success Criteria

- Mock mode enabled with one env toggle.
- Benchmark completes with `http_errors=0`.
- 3-run p99 dataset produced for isolation analysis.
