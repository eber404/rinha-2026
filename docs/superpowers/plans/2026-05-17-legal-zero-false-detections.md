# Legal Zero False Detections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce `false_positive_detections` and `false_negative_detections` toward zero without test-data lookup or benchmark-case memorization.

**Architecture:** Only use allowed reference artifacts (`dataset_full.bin`, `labels_full.bin`, rules, manifest, IVF index) for mining and calibration. Promote direct rules only when they are zero-error on allowed data, keep uncertain traffic in `AMBIGUOUS`, and spend more native work only on ambiguous/boundary cases. Docker resource totals must not increase; CPU can only be rebalanced between services.

**Tech Stack:** C++20 native engine and preprocess tooling, Bun API, Docker Compose resource limits, existing `make test-native` and `make benchmark` harnesses.

---

## File Ownership Map

- `scripts/preprocess.cpp`
  - Expand legal safe-leaf mining and add a deterministic self-test mode for rule safety.
- `fraud-api/native/engine.h`
  - Keep runtime and preprocess rule capacity in sync.
- `fraud-api/native/tests/engine_smoke.cpp`
  - Keep test fixture structs tied to runtime constants.
- `fraud-api/native/knn.cpp`
  - Add adaptive boundary refinement for ambiguous IVF decisions.
- `fraud-api/native/knn.h`
  - Declare helper methods needed by adaptive refinement.
- `Makefile`
  - Compile/run preprocess self-test from `make test-native`.
- `docker-compose.yml`
  - Rebalance CPU from LB to API containers without increasing total CPU or memory.

---

### Task 1: Preprocess Self-Test Gate

**Files:**
- Modify: `Makefile`
- Modify: `scripts/preprocess.cpp`

- [ ] **Step 1: Add failing self-test command to native test target**

```make
test-native:
	mkdir -p /tmp
	g++ -O2 -std=c++20 fraud-api/native/tests/engine_smoke.cpp fraud-api/native/knn.cpp fraud-api/native/ambiguous_head.cpp fraud-api/native/binding.cpp -o /tmp/engine_smoke
	/tmp/engine_smoke
	g++ -O2 -std=c++20 fraud-api/native/tests/ambiguous_head_smoke.cpp fraud-api/native/ambiguous_head.cpp -o /tmp/ambiguous_head_smoke
	/tmp/ambiguous_head_smoke
	g++ -O2 -std=c++20 scripts/preprocess.cpp -lz -o /tmp/preprocess_self_test
	/tmp/preprocess_self_test --self-test
```

- [ ] **Step 2: Run failing test**

Run: `make test-native`

Expected: fails because `scripts/preprocess.cpp` does not implement `--self-test` yet.

- [ ] **Step 3: Implement deterministic self-test**

Add `run_self_test()` in `scripts/preprocess.cpp` that creates small legit/fraud vectors, runs `mine_safe_leaves`, validates every mined leaf against the fixture, and returns non-zero on unsafe leaves or zero mined leaves.

- [ ] **Step 4: Run passing test**

Run: `make test-native`

Expected: all native smoke tests and preprocess self-test pass.

---

### Task 2: Expand Zero-Error Safe Leaves

**Files:**
- Modify: `scripts/preprocess.cpp`
- Modify: `fraud-api/native/engine.h`
- Modify: `fraud-api/native/tests/engine_smoke.cpp`

- [ ] **Step 1: Write failing capacity check in self-test**

Update `run_self_test()` to fail unless `FRAUD_MAX_RULE_LEAVES >= 256` and fixture test structs use `FRAUD_MAX_RULE_LEAVES`.

- [ ] **Step 2: Run failing test**

Run: `make test-native`

Expected: fails because current capacity is lower or test fixture is hardcoded.

- [ ] **Step 3: Increase rule capacity and sync test fixture**

Set `FRAUD_MAX_RULE_LEAVES` to `256` in both runtime and preprocess constants. Replace hardcoded `RulesModel::RuleLeaf leaves[128]` with `RulesModel::RuleLeaf leaves[FRAUD_MAX_RULE_LEAVES]` in `engine_smoke.cpp`.

- [ ] **Step 4: Expand mining grids conservatively**

Add more zero-error candidates using existing `add_leaf_if_safe()` validation:
- fraud feature groups: `{0,2,7,8}`, `{0,2,7,11}`, `{1,2,7,12}`, `{2,6,7,8}`, `{2,7,8,12}`
- legit feature groups: `{0,2,7,8}`, `{0,2,7,10}`, `{0,2,12,13}`
- Keep every candidate validated over allowed data before serialization.

- [ ] **Step 5: Run tests and regenerate metadata**

Run: `make test-native && make preprocess`

Expected: tests pass, preprocess writes `rules_model.bin` with a safe leaf count up to 256.

---

### Task 3: Ambiguous Boundary Mapping Guardrail

**Files:**
- Modify: `fraud-api/native/knn.cpp`
- Modify: `fraud-api/native/tests/engine_smoke.cpp`

- [ ] **Step 1: Add failing smoke assertions for boundary mapping**

In `engine_smoke.cpp`, add fixtures where IVF returns `0.4` and `0.6` on production-size datasets. Assert runtime keeps the known-best bounded mapping `0.4 -> 0.6` and `0.6 -> 0.4` without triggering full-dataset exact scans.

- [ ] **Step 2: Run failing test**

Run: `make test-native`

Expected: fails while the guarded boundary behavior is missing or changed.

- [ ] **Step 3: Preserve bounded boundary mapping**

In `score_vector_fallback()`, keep the bounded mapping for exact boundary scores and do not call `score_knn_full()` for production-size ambiguous traffic. Exact full scans caused p99 timeout and LB backpressure during execution.

- [ ] **Step 4: Run passing test**

Run: `make test-native`

Expected: boundary fixture passes and existing smoke tests remain green.

---

### Task 4: Rebalance Docker CPU Without Increasing Total

**Files:**
- Modify: `docker-compose.yml`

- [ ] **Step 1: Change CPU split only**

Set API containers to `0.38` CPU each and LB to `0.09` CPU. Keep memory unchanged at `128MB` per service. Total CPU remains `0.85` and total memory remains `384MB`.

- [ ] **Step 2: Verify compose resource totals manually**

Confirm runtime services total `0.38 + 0.38 + 0.09 = 0.85` CPU and `128MB * 3 = 384MB`.

---

### Task 5: Final Build And Benchmark Loop

**Files:**
- Generated: `fraud-api/native/build/knn.so`
- Generated: `vector-index/rules_model.bin`
- Generated: `vector-index/manifest.bin`

- [ ] **Step 1: Build native artifact**

Run: `g++ -O3 -std=c++20 -flto -fPIC -shared -o fraud-api/native/build/knn.so fraud-api/native/knn.cpp fraud-api/native/ambiguous_head.cpp fraud-api/native/binding.cpp`

Expected: `fraud-api/native/build/knn.so` rebuilt from current C++ sources. Host Bun is not required for this build path.

---

## Execution Notes

- Expanded safe-leaf capacity and mining to 256 zero-error leaves on allowed reference data.
- Tested `k_default=3`; it regressed to `FP=602`, `FN=641`, so `k_default=5` was restored.
- Tested full exact refinement for `0.4`/`0.6` boundary cases; it caused `p99~2001ms` and `http_errors=2245`, so it was rejected.
- Tested no-flip boundary mapping; it regressed to `FP=601`, `FN=664`, so it was rejected.
- Tested asymmetric `0.6 -> 0.4` only; it regressed to `FP=207`, `FN=1041`, so it was rejected.
- Final retained candidate preserves previous classification metrics with improved tests and legal rule-mining capacity: `FP=581`, `FN=646`, `http_errors=0`, `p99=1.81ms`.

- [ ] **Step 2: Restart APIs**

Run: `docker compose restart api-1 api-2`

Expected: both API containers restart and load the rebuilt native artifact.

- [ ] **Step 3: Run benchmark**

Run: `make benchmark`

Expected: `http_errors=0`; compare FP/FN against previous baseline `581/646`.

- [ ] **Step 4: Repeat benchmark if improved**

Run: `make benchmark && make benchmark`

Expected: confirm stability before keeping the candidate.

---

## Self-Review

- Spec coverage: plan avoids test lookup, uses legal reference artifacts, keeps fallback conservative, and preserves Docker total resources.
- Placeholder scan: no placeholders or undefined follow-up tasks remain.
- Type consistency: runtime/preprocess capacity constants and fixture structs are explicitly synchronized.
