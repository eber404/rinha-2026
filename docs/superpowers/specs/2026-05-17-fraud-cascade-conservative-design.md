# Fraud Detection Cascade (Conservative-First) Design

Date: 2026-05-17
Status: Approved in brainstorming, pending implementation
Scope: `fraud-api/`, native C++ engine, preprocess pipeline, E2E integration

## 1) Context and Objective

Current stack uses Bun API + native C++ vector search (IVF/KNN) over Rinha reference data.

Goal is to migrate to cascade architecture that prioritizes correctness and reliability before performance optimization:

1. Correctness
2. `http_errors = 0`
3. `failure_rate = 0`
4. Lower `p99`
5. Model sophistication

New runtime flow:

```txt
payload
  -> normalize to vector[14]
  -> conservative rules/tree
  -> clear legit/fraud => final response
  -> ambiguous => vector fallback
```

GBDT is optional and explicitly deferred unless it is low-risk and benchmark-validated.

## 2) Hard Constraints

- Keep official normalization behavior and preserve sentinel `-1` in vector indices 5 and 6.
- Keep business output rule: `approved = fraud_score < 0.6`.
- Use squared Euclidean distance (no `sqrt`).
- Keep `k` configurable.
- No relevant per-request allocation in hot path.
- No per-request file reads.
- Load models/datasets/indices at startup.
- Keep native internals in C++, public ABI in C only.
- Do not relax benchmark criteria or mask failures.

## 3) Public Native ABI

Public interface remains minimal:

```cpp
extern "C" {
  int fraud_init(const char* dataset_path);
  float fraud_score(const float* vector14);
  void fraud_close();
}
```

Design intent:

- `fraud_init`: validates and loads all required artifacts.
- `fraud_score`: executes cascade; returns final score `[0,1]`.
- `fraud_close`: clean shutdown and resource release.

`extern "C"` is used only on this API boundary.

## 4) Runtime Architecture

### 4.1 Bun Layer (`fraud-api/src/index.ts`)

- Load native library at startup.
- Call `fraud_init(...)`; fail fast when init fails.
- Keep vectorization in TS (`Float32Array(14)`) using official rules.
- For each request:
  - Parse payload
  - Normalize vector
  - Call `fraud_score`
  - Return `{ approved: score < 0.6, fraud_score: score }`

No silent approval fallback for native initialization failures.

### 4.2 Native Layer (C++)

Pipeline inside `fraud_score`:

1. `ConservativeRulesTree`:
   - outputs `CLEAR_LEGIT`, `CLEAR_FRAUD`, or `AMBIGUOUS`
   - only returns clear class on high confidence
2. If `AMBIGUOUS`: `VectorFallbackEngine`
   - first try deterministic bucket subset (when enabled and valid)
   - fallback to global full index when bucket is weak/invalid/insufficient
3. Return final `fraud_score`

Interpretation contract:

- clear legit score: low fixed score (default `0.0`)
- clear fraud score: high fixed score (default `1.0`)
- ambiguous: KNN-derived score `fraud_neighbors / k`

## 5) Model Strategy

### 5.1 Conservative Rules/Tree (Required)

- Small, interpretable, threshold-based tree/rules.
- Thresholds start restrictive to avoid direct misclassification.
- Uncertain cases always route to vector fallback.
- Thresholds configurable and calibratable.

### 5.2 GBDT (Optional, Deferred by Default)

GBDT is not part of mandatory first delivery.

Enable only if all are true:

- no heavy dependencies
- no build complexity regression
- startup-loadable artifact
- no per-request allocation
- benchmark validation shows no `failure_rate` regression

If any risk appears, keep GBDT disabled/absent and rely on conservative tree + vector fallback.

## 6) Data and Artifact Design

Preprocess reads official 3M references and outputs startup artifacts.

### 6.1 Mandatory Artifacts

- `dataset_full.bin`
- `labels_full.bin`
- global vector index metadata/artifact(s) for KNN search
- `rules_model.bin` (conservative thresholds/tree)
- manifest/version metadata (magic/version/dims/checks)

### 6.2 Optional Artifacts

- deterministic bucket mapping/list files
- IVF flat index artifact(s)
- `gbdt_model.bin`

### 6.3 Consistency Rule

Ambiguity logic used in build must be exactly same logic used at runtime.

Implementation implication:

- serialize canonical rules/threshold params from preprocess
- runtime consumes serialized params directly
- avoid duplicate hand-coded threshold logic in separate paths

### 6.4 Safety Rule

Never depend only on reduced subset when confidence is weak.

- bucket empty/small/missing/corrupt => global full fallback
- artifact mismatch/version mismatch => `fraud_init` fails fast

## 7) Vector Fallback Plan

Implementation order is incremental:

1. Full global KNN exact search (safe baseline)
2. Deterministic buckets to reduce candidate set
3. IVF flat (only if benchmark proves needed)

Core requirements:

- squared L2 distance
- no `sqrt`
- configurable `k`
- startup-loaded structures
- no per-request file I/O
- no relevant per-request allocations

## 8) Calibration Strategy

Use internal split over official references:

- train/calibrate split: 90/10
- optimize with strict objective ordering:
  1. no init/runtime HTTP instability
  2. `failure_rate = 0`
  3. then lower p99

Threshold changes are conservative-first:

- start tight (more ambiguous -> more fallback)
- relax only when `failure_rate` remains zero

## 9) Error Handling and Fail-Fast Behavior

### Startup

- missing artifact => init failure
- invalid version/dims/checksum => init failure
- incompatible optional artifact => disable optional path, keep safe baseline when possible

### Request path

- malformed input handled at API layer (HTTP 400)
- native scoring path does not read files and does not allocate heavy memory
- uncertain bucket path always escalates to global fallback

## 10) Observability and Metrics

Add counters to report cascade behavior:

- `clear_legit`
- `clear_fraud`
- `ambiguous`
- `fallback_bucket`
- `fallback_full`
- `gbdt_used` (if enabled)
- init/load error counters

Derived delivery metrics:

- `% resolved by cascade` = `(clear_legit + clear_fraud) / total`
- `% sent to vector fallback` = `ambiguous / total`
- `% bucket fallback` and `% full fallback`

These metrics support tuning while protecting `failure_rate`.

## 11) E2E Integration Scope

Must stay compatible with existing stack:

- load balancer
- Bun API
- native C++ engine via Bun FFI
- Docker Compose
- Makefile
- official benchmark flow

No benchmark-script relaxation or score masking.

## 12) Validation and Rollout Gates

Benchmark command:

```bash
make benchmark
```

Analyze output in `.benchmark`.

Rollout gates:

1. `http_errors = 0` (blocker)
2. `failure_rate = 0` (blocker)
3. optimize p99 after gates 1 and 2 pass

Go/No-Go rules:

- if `http_errors > 0`: stop optimization, fix stability
- if `failure_rate > 0`: tighten thresholds / increase global fallback usage
- reject any optimization that increases `failure_rate`

## 13) Implementation Phases

### Phase A (Mandatory)

- conservative rules/tree
- full global KNN fallback
- startup artifact loading + fail-fast
- E2E benchmark stabilization

### Phase B (Conditional)

- deterministic buckets
- strict fallback-to-global safety
- benchmark verify no detection regression

### Phase C (Optional)

- IVF flat and/or GBDT
- only with proven p99 benefit and zero detection regression

## 14) Accepted Trade-offs

- More ambiguous routing initially accepted to protect correctness.
- Early p99 may be higher than aggressive model paths.
- Complexity intentionally shifted from runtime uncertainty to explicit safety gates.

This trade-off is intentional and aligned with success criteria.
