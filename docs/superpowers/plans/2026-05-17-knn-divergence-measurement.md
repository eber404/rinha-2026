# KNN Divergence Measurement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure where runtime IVF scoring diverges from exact KNN k=5 so the next tuning pass targets real approximation error instead of guessing.

**Architecture:** Add an offline C++ measurement tool that loads the same `dataset_full.bin`, `labels_full.bin`, `ivf_index.bin`, `rules_model.bin`, and `manifest.bin` artifacts as runtime. For sampled legal reference vectors, compare direct-rule decisions, IVF top-k score, runtime boundary-mapped score, and exact brute-force KNN score. Emit aggregate disagreement counts and a small JSONL sample of disagreements for later analysis.

**Tech Stack:** C++20, existing binary vector-index artifacts, existing Makefile/native test flow, no runtime hot-path changes.

---

## File Ownership Map

- `scripts/measure_knn_divergence.cpp`
  - New offline analyzer. Owns artifact loading, exact KNN, IVF search, direct-rule replay, metrics, and self-test.
- `Makefile`
  - Adds `test-divergence` and `measure-divergence` targets.
- `docs/superpowers/specs/2026-05-17-knn-divergence-results.md`
  - Captures first measured divergence snapshot and interpretation.

---

### Task 1: RED Test Target

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Add failing test target**

Add this target:

```make
test-divergence:
	mkdir -p /tmp
	g++ -O2 -std=c++20 scripts/measure_knn_divergence.cpp -o /tmp/measure_knn_divergence
	/tmp/measure_knn_divergence --self-test
```

- [ ] **Step 2: Run the failing test**

Run: `make test-divergence`

Expected: FAIL because `scripts/measure_knn_divergence.cpp` does not exist yet.

---

### Task 2: Minimal Analyzer Self-Test

**Files:**
- Create: `scripts/measure_knn_divergence.cpp`

- [ ] **Step 1: Implement self-test fixture**

Create a small in-memory dataset with five vectors where exact KNN returns `3/5 = 0.6`, IVF search over one cluster returns the same labels, and decision disagreement count is zero.

- [ ] **Step 2: Run GREEN test**

Run: `make test-divergence`

Expected: PASS and output includes `self-test: ok`.

---

### Task 3: Real Artifact Measurement

**Files:**
- Modify: `scripts/measure_knn_divergence.cpp`
- Modify: `Makefile`

- [ ] **Step 1: Add real-data CLI**

Support:

```bash
scripts/measure_knn_divergence --data-dir vector-index --samples 200 --stride 15485863 --output artifacts/knn_divergence_samples.jsonl
```

Output aggregate lines:

```txt
samples=200
direct_clear=...
ambiguous=...
ivf_exact_score_disagree=...
ivf_exact_decision_disagree=...
runtime_exact_decision_disagree=...
```

- [ ] **Step 2: Add Makefile runner**

Add:

```make
measure-divergence:
	mkdir -p artifacts
	g++ -O3 -std=c++20 scripts/measure_knn_divergence.cpp -o /tmp/measure_knn_divergence
	/tmp/measure_knn_divergence --data-dir vector-index --samples 200 --stride 15485863 --output artifacts/knn_divergence_samples.jsonl
```

- [ ] **Step 3: Run real measurement**

Run: `make measure-divergence`

Expected: command exits 0 and writes `artifacts/knn_divergence_samples.jsonl`.

---

### Task 4: Document Results

**Files:**
- Create: `docs/superpowers/specs/2026-05-17-knn-divergence-results.md`

- [ ] **Step 1: Record command and metrics**

Include exact command, sample count, disagreement counts, and top interpretation.

- [ ] **Step 2: Identify next tuning target**

If `ivf_exact_decision_disagree` is high, target IVF recall/nprobe or micro-index. If direct-rule disagreement is high, target rules demotion. If runtime/exact only differs on boundary mapping, target boundary calibration.

---

### Task 5: Ambiguous-Only Measurement

**Files:**
- Modify: `scripts/measure_knn_divergence.cpp`
- Modify: `Makefile`

- [ ] **Step 1: Add failing ambiguous-only target**

Add `measure-divergence-ambiguous` to `Makefile` using `--only-ambiguous`.

Run: `make measure-divergence-ambiguous`

Expected: FAIL before CLI supports `--only-ambiguous`.

- [ ] **Step 2: Implement `--only-ambiguous`**

Skip direct-clear samples before exact scoring. Continue stepping through legal reference vectors until `samples` ambiguous rows are measured or the dataset is exhausted.

- [ ] **Step 3: Run focused measurements**

Run:

```bash
make measure-divergence-ambiguous
mkdir -p artifacts && /tmp/measure_knn_divergence --data-dir vector-index --samples 500 --stride 15485863 --only-ambiguous --output artifacts/knn_divergence_ambiguous_500.jsonl
```

Expected: reports focused ambiguous-path IVF/exact disagreement counts.

---

## Self-Review

- Spec coverage: measures direct-rule, IVF, runtime-mapped, ambiguous-only, and exact KNN divergence without using test payloads.
- Placeholder scan: no placeholders remain.
- Type consistency: analyzer uses the same dimensions, k, rule model layout, and manifest fields as native runtime.
