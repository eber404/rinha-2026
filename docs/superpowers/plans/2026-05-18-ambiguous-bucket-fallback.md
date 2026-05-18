# Ambiguous Bucket Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace fragile global-IVF behavior on ambiguous cases with deterministic bucket-local refinement that improves decision fidelity without global exact-KNN latency blowups.

**Architecture:** Keep conservative direct rules unchanged. In ambiguous flow, run current fast IVF pass first, then trigger selective refinement only for uncertain cases. Refinement executes exact-KNN over deterministic bucket subsets (same/near bucket) using precomputed per-vector bucket keys.

**Tech Stack:** C++20 native engine, Bun API runtime, docker-compose, existing native smoke tests + benchmark.

---

### Task 1: Add deterministic bucket model in native engine

**Files:**
- Modify: `fraud-api/native/knn.h`
- Modify: `fraud-api/native/knn.cpp`
- Modify: `fraud-api/native/engine.h`

- [ ] Add bucket-key helpers (bit-packed categorical/binned features) and precompute `bucket_keys_` at load.
- [ ] Add bucket-local exact scoring routine for same-bucket and near-bucket expansion.
- [ ] Add runtime counters for trigger/use/fallback observability.

### Task 2: Replace ambiguous fallback strategy with selective refinement

**Files:**
- Modify: `fraud-api/native/knn.cpp`

- [ ] Keep fast IVF as stage 1.
- [ ] Add uncertainty gate (score boundary band + weak-topK spread) to trigger bucket refinement.
- [ ] Execute exact-KNN over same bucket first; expand to neighbor buckets only if candidates are insufficient.
- [ ] Use refined score only when valid candidates found; otherwise preserve current IVF behavior.

### Task 3: Update smoke tests for bucket fallback behavior

**Files:**
- Modify: `fraud-api/native/tests/engine_smoke.cpp`

- [ ] Add fixture/test that forces ambiguous path and validates bucket refinement changes output for uncertain cases.
- [ ] Keep existing boundary and ambiguous-head tests passing.

### Task 4: Operational integrity and verification

**Files:**
- Modify: `docker-compose.yml` (already fixed)
- Modify: `fraud-api/Dockerfile` (already fixed)

- [ ] Keep native build isolation (`rinha-native-build`) and correct native compile unit list (`ambiguous_head.cpp`).
- [ ] Run `make test-native`.
- [ ] Run `make benchmark` and compare baseline: p99, FP/FN, failure_rate, final_score.

### Task 5: Commit

**Files:**
- Modify: all touched files above

- [ ] Commit with focused message describing bucket-local ambiguous refinement.
- [ ] Push `chore/bun`.
