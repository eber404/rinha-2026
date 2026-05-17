# Zero Failure Ambiguous Head Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce benchmark `false_positive_detections`, `false_negative_detections`, and `failure_rate` to zero by improving only `AMBIGUOUS` decisions while preserving conservative direct rules.

**Architecture:** Keep `CLEAR_LEGIT` and `CLEAR_FRAUD` rule paths unchanged. Add a lightweight calibrated head for `AMBIGUOUS` cases only, fed by IVF/KNN confidence features. Protect rollout with runtime flags and strict benchmark checkpoints.

**Tech Stack:** C++20 native engine, Bun API, Python offline training/eval scripts, existing `make benchmark` harness.

---

## File Ownership Map

- `fraud-api/native/knn.cpp`
  - Add ambiguous feature extraction and head invocation in fallback path.
- `fraud-api/native/knn.h`
  - Declare head-related structures/methods and flags.
- `fraud-api/native/engine.h`
  - Extend runtime model metadata for optional ambiguous head artifact.
- `fraud-api/native/ambiguous_head.h` (new)
  - Header-only model structure and inference API.
- `fraud-api/native/ambiguous_head.cpp` (new)
  - Model loading and inference implementation.
- `fraud-api/native/tests/ambiguous_head_smoke.cpp` (new)
  - Deterministic inference and loading tests.
- `fraud-api/native/tests/engine_smoke.cpp`
  - Integration tests for `AMBIGUOUS -> head` path and fallback behavior.
- `scripts/preprocess.cpp`
  - Generate/load metadata for ambiguous head artifact path/version.
- `scripts/train_ambiguous_head.py` (new)
  - Train head on ambiguous-only samples.
- `scripts/eval_ambiguous_head.py` (new)
  - Offline evaluation and threshold sweep for weighted error objective.
- `scripts/export_ambiguous_dataset.py` (new)
  - Export ambiguous samples from benchmark/reference data.
- `fraud-api/src/index.ts`
  - Add env flags for safe rollout and diagnostics pass-through.
- `docs/superpowers/specs/2026-05-17-ambiguous-head-design.md` (new)
  - Design + threshold rationale + benchmark comparison.

---

## Operational Checkpoints (Go/No-Go)

1. **CP1 Data Quality Gate**
   - `AMBIGUOUS` dataset exported with stable schema.
   - No missing features; label consistency verified.
2. **CP2 Offline Model Gate**
   - Offline eval beats baseline IVF-only on ambiguous subset for weighted errors.
3. **CP3 Integration Safety Gate**
   - All native tests pass, no regressions in direct rule paths.
4. **CP4 Benchmark Gate**
   - `http_errors = 0` preserved.
   - `failure_rate` decreases vs baseline.
   - `p99` remains within agreed latency budget.
5. **CP5 Zero-Error Attempt Gate**
   - If zero not achieved after 3 threshold/model iterations, stop and publish residual-error analysis with next-best configuration.

---

### Task 1: Baseline + Ambiguous Export

**Files:**
- Create: `scripts/export_ambiguous_dataset.py`
- Modify: `fraud-api/native/knn.cpp`
- Create: `docs/superpowers/specs/2026-05-17-ambiguous-head-design.md`

- [ ] **Step 1: Add temporary ambiguous diagnostics counters**

```cpp
// in fallback path counters
// ambiguous_total, ambiguous_ivf_lt_04, ambiguous_ivf_04_06, ambiguous_ivf_gt_06
```

- [ ] **Step 2: Export ambiguous dataset**

Run: `python3 scripts/export_ambiguous_dataset.py`
Expected: file like `vector-index/ambiguous_samples.jsonl` with features + label + ivf score.

- [ ] **Step 3: Capture baseline benchmark**

Run: `make benchmark`
Expected: baseline metrics persisted in design doc.

- [ ] **Step 4: Commit**

```bash
git add scripts/export_ambiguous_dataset.py fraud-api/native/knn.cpp docs/superpowers/specs/2026-05-17-ambiguous-head-design.md
git commit -m "chore(fraud): export ambiguous benchmark samples"
```

---

### Task 2: Build Minimal Ambiguous Head (Offline)

**Files:**
- Create: `scripts/train_ambiguous_head.py`
- Create: `scripts/eval_ambiguous_head.py`

- [ ] **Step 1: Write failing evaluation assertion**

```python
assert candidate_weighted_error < baseline_weighted_error
```

- [ ] **Step 2: Run eval to verify failure before training**

Run: `python3 scripts/eval_ambiguous_head.py --baseline-only`
Expected: assertion fails (no model / no improvement).

- [ ] **Step 3: Implement trainer + threshold sweep**

```python
# Train linear/logistic head on ambiguous subset
# Sweep threshold to minimize weighted error (fp*1 + fn*3)
```

- [ ] **Step 4: Re-run eval**

Run: `python3 scripts/eval_ambiguous_head.py`
Expected: weighted error improved on validation split.

- [ ] **Step 5: Commit**

```bash
git add scripts/train_ambiguous_head.py scripts/eval_ambiguous_head.py
git commit -m "feat(fraud): train ambiguous-only linear head"
```

---

### Task 3: Integrate Head into Native Runtime

**Files:**
- Create: `fraud-api/native/ambiguous_head.h`
- Create: `fraud-api/native/ambiguous_head.cpp`
- Modify: `fraud-api/native/knn.h`
- Modify: `fraud-api/native/knn.cpp`
- Modify: `fraud-api/native/engine.h`

- [ ] **Step 1: Add failing native smoke for ambiguous head path**

```cpp
// expects ambiguous sample to route through head when enabled
```

- [ ] **Step 2: Run failing test**

Run: `make test-native`
Expected: fails on missing head integration.

- [ ] **Step 3: Implement load + infer with safe fallback**

```cpp
if (!head_enabled || !head_loaded) return ivf_score;
return infer_ambiguous_head(features);
```

- [ ] **Step 4: Re-run native tests**

Run: `make test-native`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fraud-api/native/ambiguous_head.h fraud-api/native/ambiguous_head.cpp fraud-api/native/knn.h fraud-api/native/knn.cpp fraud-api/native/engine.h
git commit -m "feat(fraud): integrate ambiguous head in native path"
```

---

### Task 4: Rollout Flags + Safety Guardrails

**Files:**
- Modify: `fraud-api/src/index.ts`
- Modify: `fraud-api/native/knn.cpp`
- Modify: `fraud-api/native/knn.h`

- [ ] **Step 1: Add env-gated behavior**

```ts
// FRAUD_AMBIGUOUS_HEAD=on|off
```

- [ ] **Step 2: Add counters for head usage**

```cpp
// ambiguous_head_used, ambiguous_head_bypassed
```

- [ ] **Step 3: Validate disabled mode parity**

Run: `FRAUD_AMBIGUOUS_HEAD=off make benchmark`
Expected: matches baseline behavior.

- [ ] **Step 4: Commit**

```bash
git add fraud-api/src/index.ts fraud-api/native/knn.cpp fraud-api/native/knn.h
git commit -m "chore(fraud): add ambiguous-head rollout flags"
```

---

### Task 5: Benchmark Iteration Loop (Closed)

**Files:**
- Modify: `scripts/train_ambiguous_head.py`
- Modify: `scripts/eval_ambiguous_head.py`
- Modify: `docs/superpowers/specs/2026-05-17-ambiguous-head-design.md`

- [ ] **Step 1: Iteration 1 (head on)**

Run: `FRAUD_AMBIGUOUS_HEAD=on make benchmark`
Expected: failure rate below baseline.

- [ ] **Step 2: Threshold adjust + retrain**

Run: `python3 scripts/train_ambiguous_head.py --retune`
Expected: new artifact generated.

- [ ] **Step 3: Iteration 2 benchmark**

Run: `FRAUD_AMBIGUOUS_HEAD=on make benchmark`
Expected: additional error reduction.

- [ ] **Step 4: Iteration 3 + stop rule**

Run: `FRAUD_AMBIGUOUS_HEAD=on make benchmark`
Expected: either zero errors or stop with best-known config and residual analysis.

- [ ] **Step 5: Commit best configuration**

```bash
git add scripts/train_ambiguous_head.py scripts/eval_ambiguous_head.py docs/superpowers/specs/2026-05-17-ambiguous-head-design.md
git commit -m "perf(fraud): tune ambiguous head for benchmark errors"
```

---

### Task 6: Final Validation + Cleanup

**Files:**
- Modify: `fraud-api/native/tests/engine_smoke.cpp`
- Create: `fraud-api/native/tests/ambiguous_head_smoke.cpp`
- Modify: docs as needed

- [ ] **Step 1: Final native test run**

Run: `make test-native`
Expected: PASS.

- [ ] **Step 2: Final benchmark x3**

Run: `make benchmark` (3 times)
Expected: stable metrics and no `http_errors`.

- [ ] **Step 3: Remove temporary diagnostics not needed in prod**

```cpp
// keep only durable counters
```

- [ ] **Step 4: Commit final cleanup**

```bash
git add fraud-api/native/tests/engine_smoke.cpp fraud-api/native/tests/ambiguous_head_smoke.cpp
git commit -m "test(fraud): finalize ambiguous head validation"
```

---

## Exit Criteria

- Primary target: `false_positive_detections = 0`, `false_negative_detections = 0`, `failure_rate = 0%`
- Hard constraints: `http_errors = 0`, no direct-rule correctness regressions
- Performance constraint: no unacceptable `p99` regression from current production baseline

If primary target is not reached after 3 closed iterations, ship best-known config and publish residual-error report with top failure slices and next experiments.
