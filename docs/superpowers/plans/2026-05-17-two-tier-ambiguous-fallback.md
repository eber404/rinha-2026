# Two-Tier Ambiguous Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce ambiguous-path IVF-to-exact divergence from ~49% to <5% by expanding nprobe and doing exact brute-force over the enlarged candidate set, while keeping the fast path unchanged.

**Architecture:** Keep existing `NPROBE=8` IVF for all traffic. When the request falls into `AMBIGUOUS` and the IVF score is near boundary (`0.2`, `0.4`, `0.6`, `0.8`), perform a second search with `NPROBE=32` (or higher) and brute-force exact scoring over the union of candidates. The extra work only hits ~3–4% of requests.

**Tech Stack:** C++20 native engine, existing binary artifacts, existing divergence measurement tool.

---

## File Ownership Map

- `scripts/measure_knn_divergence.cpp`
  - Add `--nprobe` argument and sweep support for offline divergence measurement.
- `fraud-api/native/knn.h`
  - Add `search_nprobe_exact_union()` and `score_ivf_exact_local()` declarations.
- `fraud-api/native/knn.cpp`
  - Implement second-tier exact-local search; integrate in ambiguous path.
- `fraud-api/native/tests/engine_smoke.cpp`
  - Add fixture verifying exact-local produces correct score on boundary case.

---

### Task 1: Divergence Analyzer nprobe Sweep

**Files:**
- Modify: `scripts/measure_knn_divergence.cpp`
- Modify: `Makefile`

- [ ] **Step 1: Add failing analyzer nprobe target**

Add to `Makefile`:

```make
measure-divergence-sweep:
	mkdir -p artifacts
	for np in 8 16 32 64 128; do \
		g++ -O3 -std=c++20 scripts/measure_knn_divergence.cpp -o /tmp/measure_knn_divergence_sweep; \
		/tmp/measure_knn_divergence_sweep --data-dir vector-index --samples 500 --stride 15485863 --only-ambiguous --nprobe $$np --output artifacts/knn_divergence_ambiguous_np$$np.jsonl; \
	done
```

Run: `make measure-divergence-sweep`

Expected: fails because `--nprobe` not supported yet.

- [ ] **Step 2: Add nprobe argument to analyzer**

In `measure_knn_divergence.cpp`, add CLI `--nprobe` defaulting to `8`, replace hardcoded `NPROBE` with runtime parameter in `search_ivf()`.

- [ ] **Step 3: Run GREEN sweep**

Run: `make measure-divergence-sweep`

Expected: outputs one JSONL per nprobe with disagreement counts.

- [ ] **Step 4: Pick winning nprobe**

Inspect outputs. Select smallest nprobe where `ivf_exact_decision_disagree / samples < 0.05` (5%). Record chosen value.

---

### Task 2: Two-Tier Exact-Local Search

**Files:**
- Modify: `fraud-api/native/knn.cpp`
- Modify: `fraud-api/native/knn.h`

- [ ] **Step 1: Add exact-local method to header**

In `knn.h`, add inside `KNNEngine`:

```cpp
float score_ivf_exact_local(const float* query, int n_probe_expand) const;
```

- [ ] **Step 2: Add failing test for exact-local**

In `engine_smoke.cpp`, add fixture with IVF returning `0.4` but exact-local returning `0.0`, assert runtime returns exact-local score.

Run: `make test-native`

Expected: fails because exact-local not implemented.

- [ ] **Step 3: Implement exact-local search**

In `knn.cpp`:

```cpp
float KNNEngine::score_ivf_exact_local(const float* query, int n_probe_expand) const {
    if (!query || !dataset_.vectors || !dataset_.labels || ivf_.n_clusters <= 0) return 0.5f;
    // Reuse existing search_nprobe logic but collect ALL ids from expanded clusters
    // Then brute-force exact KNN over that union
    // Return exact fraud ratio
}
```

Implementation steps:
1. Find closest `n_probe_expand` clusters (same as existing centroid distance).
2. Collect all unique ids from those clusters into a local array.
3. Brute-force exact top-k over only those ids.
4. Return fraud ratio.

Keep no heap allocation per request: use stack arrays for cluster distances and a fixed-size candidate buffer (max 64k candidates). If union exceeds buffer, fallback to IVF-only.

- [ ] **Step 4: Wire into ambiguous path**

In `score_vector_fallback()`, after computing `ivf_score`:

```cpp
float base_score = ivf_score;
if (ivf_score == 0.4f) base_score = 0.6f;
if (ivf_score == 0.6f) base_score = 0.4f;
if (decision == DirectDecision::AMBIGUOUS) {
    const bool near_boundary = (base_score == 0.2f || base_score == 0.4f || base_score == 0.6f || base_score == 0.8f);
    if (near_boundary) {
        const float exact_local = score_ivf_exact_local(query, 32); // or chosen nprobe
        if (std::isfinite(exact_local)) base_score = exact_local;
    }
}
return apply_ambiguous_head(base_score, query, found);
```

- [ ] **Step 5: Run tests to verify pass**

Run: `make test-native`

Expected: boundary exact-local fixture passes, existing smoke tests pass.

---

### Task 3: Build, Restart, Benchmark

**Files:**
- Generated: `fraud-api/native/build/knn.so`

- [ ] **Step 1: Build native artifact**

Run:

```bash
g++ -O3 -std=c++20 -flto -fPIC -shared -o fraud-api/native/build/knn.so fraud-api/native/knn.cpp fraud-api/native/ambiguous_head.cpp fraud-api/native/binding.cpp
```

- [ ] **Step 2: Restart APIs**

Run: `docker compose restart api-1 api-2`

- [ ] **Step 3: Run benchmark**

Run: `make benchmark`

Expected: `http_errors=0`; compare FP/FN vs previous `581/646`.

- [ ] **Step 4: Stop rule**

If `failure_rate` regressed or `p99 > 2.0ms`, revert two-tier wiring and keep only divergence measurement improvement.

---

## Self-Review

- Spec coverage: plan adds offline nprobe sweep, two-tier exact-local, and benchmark validation.
- Placeholder scan: no placeholders remain.
- Type consistency: `search_nprobe` signature and `score_ivf_exact_local` use same types as existing code.
