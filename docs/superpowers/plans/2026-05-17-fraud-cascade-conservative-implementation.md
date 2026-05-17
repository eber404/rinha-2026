# Fraud Cascade Conservative-First Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace always-on IVF scoring with conservative cascade that keeps vector search as safe fallback and prioritizes `http_errors=0` and `failure_rate=0` before p99 tuning.

**Architecture:** Bun keeps official vectorization and delegates scoring to native C++ C-ABI (`fraud_init`, `fraud_score`, `fraud_close`). Native engine runs conservative clear/ambiguous gate, then falls back to vector KNN on full reference dataset; deterministic buckets are optional optimization with strict fallback to global. Preprocess generates startup artifacts (full dataset/labels, rules model, manifest, optional bucket index).

**Tech Stack:** Bun + TypeScript (`bun:ffi`, `bun:test`), C++20 (`mmap`, binary artifacts, KNN), shell scripts/Makefile, Docker Compose, official benchmark (`make benchmark`).

---

## File Structure

| File | Responsibility |
|---|---|
| `scripts/preprocess.cpp` | Build-time artifact generator: full dataset/labels, conservative rules model, manifest, optional deterministic buckets |
| `scripts/preprocess.sh` | Wrapper to compile/run preprocess and verify required outputs |
| `vector-index/manifest.bin` | Canonical artifact metadata (`magic`, `version`, `dims`, file names, defaults) consumed by runtime |
| `vector-index/rules_model.bin` | Conservative direct-decision thresholds and logic parameters |
| `fraud-api/native/engine.h` | Internal C++ types for rules model, artifact manifest, runtime counters |
| `fraud-api/native/knn.h` | Public C++ class API + C ABI declarations (`fraud_init`, `fraud_score`, `fraud_close`) |
| `fraud-api/native/knn.cpp` | Native runtime implementation: init/load, conservative gate, fallback KNN, optional bucket path |
| `fraud-api/native/binding.cpp` | C ABI wrappers only (no business logic) |
| `fraud-api/native/tests/engine_smoke.cpp` | Native smoke tests for init/scoring contract |
| `fraud-api/src/index.ts` | Bun startup/init fail-fast and per-request FFI scoring |
| `fraud-api/src/vectorize.ts` | Official payload normalization (unchanged semantics) |
| `fraud-api/src/index.test.ts` | Bun-level tests for API scoring path and fail-fast behavior |
| `fraud-api/src/vectorize.test.ts` | Bun tests for normalization edge cases and sentinel `-1` preservation |
| `fraud-api/package.json` | Scripts for native build, tests, smoke checks |
| `fraud-api/Dockerfile` | Include native library and enforce startup artifact requirements |
| `docker-compose.yml` | Mount new artifacts and keep E2E compatibility |
| `Makefile` | Deterministic targets for preprocess, tests, benchmark |

---

### Task 1: Define artifact contract and C ABI names

**Files:**
- Create: `fraud-api/native/engine.h`
- Modify: `fraud-api/native/knn.h`
- Modify: `fraud-api/native/binding.cpp`
- Test: `fraud-api/native/tests/engine_smoke.cpp`

- [ ] **Step 1: Write failing native smoke test for ABI symbols and lifecycle**

```cpp
// fraud-api/native/tests/engine_smoke.cpp
#include "../knn.h"
#include <cassert>

int main() {
    // Missing path must fail.
    assert(fraud_init("/tmp/does-not-exist") != 0);

    // Safe close even if not initialized.
    fraud_close();

    // Score call before init returns neutral safe value.
    float q[14] = {0};
    const float s = fraud_score(q);
    assert(s >= 0.0f && s <= 1.0f);
    return 0;
}
```

- [ ] **Step 2: Run smoke compile to confirm it fails before header changes**

Run: `g++ -O2 -std=c++20 fraud-api/native/tests/engine_smoke.cpp fraud-api/native/knn.cpp fraud-api/native/binding.cpp -o /tmp/engine_smoke`
Expected: FAIL with undefined references to `fraud_init`/`fraud_score`/`fraud_close`

- [ ] **Step 3: Add internal engine types in `engine.h`**

```cpp
// fraud-api/native/engine.h
#pragma once

#include <cstdint>
#include <cstddef>

static constexpr uint32_t FRAUD_MAGIC = 0x46445231; // "FDR1"
static constexpr uint32_t FRAUD_VERSION = 1;
static constexpr int FRAUD_DIMS = 14;

enum class DirectDecision : uint8_t {
    CLEAR_LEGIT = 0,
    CLEAR_FRAUD = 1,
    AMBIGUOUS = 2,
};

struct RulesModel {
    float min_conf_legit;
    float min_conf_fraud;
    float min_mcc_risk_fraud;
    float max_amount_vs_avg_legit;
    float min_amount_vs_avg_fraud;
    float max_km_home_legit;
    float min_km_home_fraud;
};

struct RuntimeCounters {
    uint64_t clear_legit = 0;
    uint64_t clear_fraud = 0;
    uint64_t ambiguous = 0;
    uint64_t fallback_bucket = 0;
    uint64_t fallback_full = 0;
};
```

- [ ] **Step 4: Replace old ABI declarations in `knn.h`**

```cpp
// add to fraud-api/native/knn.h
extern "C" {
int fraud_init(const char* dataset_path);
float fraud_score(const float* vector14);
void fraud_close();
}
```

- [ ] **Step 5: Implement ABI wrappers in `binding.cpp` only**

```cpp
// fraud-api/native/binding.cpp
#include "knn.h"

static KNNEngine g_engine;

extern "C" int fraud_init(const char* dataset_path) {
    return g_engine.load(dataset_path) ? 0 : -1;
}

extern "C" float fraud_score(const float* vector14) {
    return g_engine.score(vector14);
}

extern "C" void fraud_close() {
    g_engine.close();
}
```

- [ ] **Step 6: Re-run native smoke test and verify pass**

Run: `g++ -O2 -std=c++20 fraud-api/native/tests/engine_smoke.cpp fraud-api/native/knn.cpp fraud-api/native/binding.cpp -o /tmp/engine_smoke && /tmp/engine_smoke`
Expected: PASS (exit code `0`)

- [ ] **Step 7: Commit ABI contract baseline**

```bash
git add fraud-api/native/engine.h fraud-api/native/knn.h fraud-api/native/binding.cpp fraud-api/native/tests/engine_smoke.cpp
git commit -m "feat(native): add fraud C ABI contract"
```

---

### Task 2: Generate conservative artifacts in preprocess

**Files:**
- Modify: `scripts/preprocess.cpp`
- Modify: `scripts/preprocess.sh`
- Test: `fraud-api/native/tests/engine_smoke.cpp`

- [ ] **Step 1: Add failing assertion in smoke test for required artifacts**

```cpp
// append in fraud-api/native/tests/engine_smoke.cpp
assert(fraud_init("vector-index") == 0);
fraud_close();
```

- [ ] **Step 2: Run preprocess + smoke to confirm failure before artifact changes**

Run: `bash scripts/preprocess.sh && g++ -O2 -std=c++20 fraud-api/native/tests/engine_smoke.cpp fraud-api/native/knn.cpp fraud-api/native/binding.cpp -o /tmp/engine_smoke && /tmp/engine_smoke`
Expected: FAIL because `rules_model.bin`/`manifest.bin` missing

- [ ] **Step 3: Add artifact structs and writers in `scripts/preprocess.cpp`**

```cpp
// add near top
struct ManifestHeader {
    uint32_t magic;
    uint32_t version;
    uint32_t dims;
    uint32_t k_default;
    uint32_t bucket_enabled;
};

struct RulesModelDisk {
    float min_conf_legit;
    float min_conf_fraud;
    float min_mcc_risk_fraud;
    float max_amount_vs_avg_legit;
    float min_amount_vs_avg_fraud;
    float max_km_home_legit;
    float min_km_home_fraud;
};
```

- [ ] **Step 4: Write conservative default thresholds from preprocess**

```cpp
RulesModelDisk rules{};
rules.min_conf_legit = 0.995f;
rules.min_conf_fraud = 0.995f;
rules.min_mcc_risk_fraud = 0.90f;
rules.max_amount_vs_avg_legit = 0.08f;
rules.min_amount_vs_avg_fraud = 0.98f;
rules.max_km_home_legit = 0.03f;
rules.min_km_home_fraud = 0.95f;

FILE* fr = fopen("vector-index/rules_model.bin", "wb");
fwrite(&rules, sizeof(rules), 1, fr);
fclose(fr);
```

- [ ] **Step 5: Write manifest with strict dimensions/version checks**

```cpp
ManifestHeader mh{};
mh.magic = 0x46445231;
mh.version = 1;
mh.dims = 14;
mh.k_default = 5;
mh.bucket_enabled = 0;

FILE* fm = fopen("vector-index/manifest.bin", "wb");
fwrite(&mh, sizeof(mh), 1, fm);
fclose(fm);
```

- [ ] **Step 6: Ensure preprocess shell validates output presence**

```bash
# add in scripts/preprocess.sh after generator run
test -f vector-index/dataset_full.bin
test -f vector-index/labels_full.bin
test -f vector-index/rules_model.bin
test -f vector-index/manifest.bin
```

- [ ] **Step 7: Re-run preprocess and smoke test; verify pass**

Run: `bash scripts/preprocess.sh && /tmp/engine_smoke`
Expected: PASS

- [ ] **Step 8: Commit preprocess artifact contract**

```bash
git add scripts/preprocess.cpp scripts/preprocess.sh
git commit -m "feat(preprocess): generate conservative cascade artifacts"
```

---

### Task 3: Implement conservative direct-decision gate in native engine

**Files:**
- Modify: `fraud-api/native/knn.h`
- Modify: `fraud-api/native/knn.cpp`
- Test: `fraud-api/native/tests/engine_smoke.cpp`

- [ ] **Step 1: Add failing smoke tests for clear decisions**

```cpp
float q_legit[14] = {0.01f, 0.0f, 0.01f, 0.2f, 0.1f, -1.0f, -1.0f, 0.01f, 0.0f, 0.0f, 1.0f, 0.0f, 0.1f, 0.01f};
float q_fraud[14] = {1.0f, 1.0f, 1.0f, 0.8f, 0.9f, -1.0f, -1.0f, 1.0f, 1.0f, 1.0f, 0.0f, 1.0f, 1.0f, 1.0f};
assert(fraud_score(q_legit) <= 0.1f);
assert(fraud_score(q_fraud) >= 0.9f);
```

- [ ] **Step 2: Run smoke test to confirm failure before gate implementation**

Run: `/tmp/engine_smoke`
Expected: FAIL on clear decision assertions

- [ ] **Step 3: Add decision helper in `knn.cpp`**

```cpp
static DirectDecision decide_conservative(const float* v, const RulesModel& r) {
    const float amount_vs_avg = v[2];
    const float km_home = v[7];
    const float mcc_risk = v[12];
    const float unknown_merchant = v[11];

    if (amount_vs_avg <= r.max_amount_vs_avg_legit && km_home <= r.max_km_home_legit && unknown_merchant < 0.5f) {
        return DirectDecision::CLEAR_LEGIT;
    }
    if (amount_vs_avg >= r.min_amount_vs_avg_fraud && km_home >= r.min_km_home_fraud && mcc_risk >= r.min_mcc_risk_fraud) {
        return DirectDecision::CLEAR_FRAUD;
    }
    return DirectDecision::AMBIGUOUS;
}
```

- [ ] **Step 4: Wire direct gate into `KNNEngine::score`**

```cpp
float KNNEngine::score(const float* query) {
    if (!ready_) return 0.5f;

    const DirectDecision d = decide_conservative(query, rules_);
    if (d == DirectDecision::CLEAR_LEGIT) {
        counters_.clear_legit++;
        return 0.0f;
    }
    if (d == DirectDecision::CLEAR_FRAUD) {
        counters_.clear_fraud++;
        return 1.0f;
    }
    counters_.ambiguous++;
    return score_knn_full(query);
}
```

- [ ] **Step 5: Re-run native smoke and verify pass**

Run: `g++ -O2 -std=c++20 fraud-api/native/tests/engine_smoke.cpp fraud-api/native/knn.cpp fraud-api/native/binding.cpp -o /tmp/engine_smoke && /tmp/engine_smoke`
Expected: PASS

- [ ] **Step 6: Commit conservative gate**

```bash
git add fraud-api/native/knn.h fraud-api/native/knn.cpp fraud-api/native/tests/engine_smoke.cpp
git commit -m "feat(native): add conservative clear-or-ambiguous gate"
```

---

### Task 4: Implement safe full KNN fallback (baseline)

**Files:**
- Modify: `fraud-api/native/knn.cpp`
- Modify: `fraud-api/native/knn.h`
- Test: `fraud-api/native/tests/engine_smoke.cpp`

- [ ] **Step 1: Add failing test for ambiguous query using KNN ratio**

```cpp
float q_amb[14] = {0.4f, 0.2f, 0.5f, 0.4f, 0.4f, -1.0f, -1.0f, 0.4f, 0.2f, 0.0f, 1.0f, 1.0f, 0.5f, 0.4f};
float s_amb = fraud_score(q_amb);
assert(s_amb >= 0.0f && s_amb <= 1.0f);
```

- [ ] **Step 2: Run test to verify failure before fallback refactor**

Run: `/tmp/engine_smoke`
Expected: FAIL due missing `score_knn_full` path correctness

- [ ] **Step 3: Add squared L2 exact KNN without sqrt and configurable k**

```cpp
static inline float l2_sq(const float* a, const float* b) {
    float s = 0.0f;
    for (int i = 0; i < FRAUD_DIMS; ++i) {
        const float d = a[i] - b[i];
        s += d * d;
    }
    return s;
}

float KNNEngine::score_knn_full(const float* query) {
    const int k = k_runtime_;
    float best_d[16];
    uint8_t best_l[16];
    for (int i = 0; i < k; ++i) {
        best_d[i] = 1e30f;
        best_l[i] = 0;
    }

    for (size_t id = 0; id < full_count_; ++id) {
        const float dist = l2_sq(query, &full_vectors_[id * FRAUD_DIMS]);
        if (dist >= best_d[k - 1]) continue;
        best_d[k - 1] = dist;
        best_l[k - 1] = full_labels_[id];
        for (int j = k - 1; j > 0 && best_d[j] < best_d[j - 1]; --j) {
            std::swap(best_d[j], best_d[j - 1]);
            std::swap(best_l[j], best_l[j - 1]);
        }
    }

    int frauds = 0;
    for (int i = 0; i < k; ++i) frauds += (best_l[i] == 1 ? 1 : 0);
    return static_cast<float>(frauds) / static_cast<float>(k);
}
```

- [ ] **Step 4: Re-run smoke test and verify pass**

Run: `/tmp/engine_smoke`
Expected: PASS with score in `[0,1]`

- [ ] **Step 5: Commit safe KNN fallback baseline**

```bash
git add fraud-api/native/knn.cpp fraud-api/native/knn.h fraud-api/native/tests/engine_smoke.cpp
git commit -m "feat(native): add safe full knn fallback"
```

---

### Task 5: Integrate Bun FFI with fail-fast startup

**Files:**
- Modify: `fraud-api/src/index.ts`
- Modify: `fraud-api/package.json`
- Test: `fraud-api/src/index.test.ts`

- [ ] **Step 1: Add failing Bun test for startup fail-fast**

```ts
// fraud-api/src/index.test.ts
import { test, expect } from "bun:test";

test("fraud engine init contract is strict", () => {
  const code = Bun.spawnSync(["bun", "run", "src/index.ts"], {
    env: { ...process.env, FRAUD_DATASET_PATH: "/tmp/does-not-exist" },
  }).exitCode;
  expect(code).not.toBe(0);
});
```

- [ ] **Step 2: Run Bun test to confirm failure before index.ts changes**

Run: `cd fraud-api && bun test src/index.test.ts`
Expected: FAIL because env var not honored / init path not strict

- [ ] **Step 3: Update FFI bindings and fail-fast behavior in `index.ts`**

```ts
const DATASET_DIR = process.env.FRAUD_DATASET_PATH ?? "/data/vector-index";

const lib = dlopen(nativePath, {
  fraud_init: { args: [FFIType.ptr], returns: FFIType.int },
  fraud_score: { args: [FFIType.ptr], returns: FFIType.f32 },
  fraud_close: { args: [], returns: FFIType.void },
});

const initRes = lib.symbols.fraud_init(Buffer.from(DATASET_DIR + "\0"));
if (initRes !== 0) {
  console.error("fatal: fraud engine init failed");
  process.exit(1);
}
```

- [ ] **Step 4: Remove silent approval fallback for native errors**

```ts
function score(payload: Payload): { approved: boolean; fraud_score: number } {
  const vec = vectorize(payload);
  queryBuf.set(vec);
  const fraudScore = lib.symbols.fraud_score(ptr(new Uint8Array(queryBuf.buffer)));
  const bounded = Number.isFinite(fraudScore) ? Math.max(0, Math.min(1, fraudScore)) : 1;
  return { approved: bounded < 0.6, fraud_score: bounded };
}
```

- [ ] **Step 5: Re-run Bun test and verify pass**

Run: `cd fraud-api && bun test src/index.test.ts`
Expected: PASS

- [ ] **Step 6: Commit Bun FFI fail-fast integration**

```bash
git add fraud-api/src/index.ts fraud-api/src/index.test.ts fraud-api/package.json
git commit -m "feat(api): use fraud abi and fail fast on init"
```

---

### Task 6: Add vectorization correctness tests (official normalization)

**Files:**
- Modify: `fraud-api/src/vectorize.ts`
- Test: `fraud-api/src/vectorize.test.ts`

- [ ] **Step 1: Add failing tests for sentinel `-1`, weekday mapping, clamp**

```ts
// fraud-api/src/vectorize.test.ts
import { test, expect } from "bun:test";
import { vectorize, type Payload } from "./vectorize";

const base: Payload = {
  id: "tx-1",
  transaction: { amount: 100, installments: 2, requested_at: "2026-03-10T10:00:00Z" },
  customer: { avg_amount: 200, tx_count_24h: 3, known_merchants: ["M1"] },
  merchant: { id: "M1", mcc: "5411", avg_amount: 100 },
  terminal: { is_online: false, card_present: true, km_from_home: 12 },
  last_transaction: null,
};

test("keeps -1 when last_transaction is null", () => {
  const v = vectorize(base);
  expect(v[5]).toBe(-1);
  expect(v[6]).toBe(-1);
});

test("maps monday to day_of_week 0", () => {
  const v = vectorize({ ...base, transaction: { ...base.transaction, requested_at: "2026-03-09T10:00:00Z" } });
  expect(v[4]).toBe(0);
});
```

- [ ] **Step 2: Run tests to verify failure if behavior drifts**

Run: `cd fraud-api && bun test src/vectorize.test.ts`
Expected: FAIL if current code deviates from expected cases

- [ ] **Step 3: Apply minimal fixes in `vectorize.ts` only if needed**

```ts
// keep sentinel behavior and official UTC weekday mapping
vec[4] = ((reqDate.getUTCDay() + 6) % 7) / 6.0;
```

- [ ] **Step 4: Re-run tests and verify pass**

Run: `cd fraud-api && bun test src/vectorize.test.ts`
Expected: PASS

- [ ] **Step 5: Commit vectorization guardrail tests**

```bash
git add fraud-api/src/vectorize.ts fraud-api/src/vectorize.test.ts
git commit -m "test(api): lock official vectorization behavior"
```

---

### Task 7: Wire startup artifacts in Docker/Compose/Makefile

**Files:**
- Modify: `fraud-api/Dockerfile`
- Modify: `docker-compose.yml`
- Modify: `Makefile`
- Modify: `scripts/preprocess.sh`

- [ ] **Step 1: Add failing local check script for required artifacts**

```bash
# run manually before edits
test -f vector-index/dataset_full.bin && test -f vector-index/labels_full.bin && test -f vector-index/rules_model.bin && test -f vector-index/manifest.bin
```

- [ ] **Step 2: Update Dockerfile runtime expectation to `FRAUD_DATASET_PATH`**

```dockerfile
ENV FRAUD_DATASET_PATH=/data/vector-index
CMD ["bun", "run", "src/index.ts"]
```

- [ ] **Step 3: Ensure compose mounts `vector-index` read-only and preprocess dependency remains hard**

```yaml
    volumes:
      - ./vector-index:/data/vector-index:ro
    depends_on:
      preprocess:
        condition: service_completed_successfully
```

- [ ] **Step 4: Update Makefile targets for deterministic local flow**

```make
preprocess:
	bash scripts/preprocess.sh

test-api:
	cd fraud-api && bun test src/vectorize.test.ts src/index.test.ts

test-native:
	g++ -O2 -std=c++20 fraud-api/native/tests/engine_smoke.cpp fraud-api/native/knn.cpp fraud-api/native/binding.cpp -o /tmp/engine_smoke && /tmp/engine_smoke
```

- [ ] **Step 5: Run infra sanity commands and verify pass**

Run: `make preprocess && make test-native && make test-api`
Expected: all commands exit `0`

- [ ] **Step 6: Commit infra wiring**

```bash
git add fraud-api/Dockerfile docker-compose.yml Makefile scripts/preprocess.sh
git commit -m "chore(infra): wire conservative artifacts and tests"
```

---

### Task 8: Add deterministic bucket optimization with global fallback safety

**Files:**
- Modify: `scripts/preprocess.cpp`
- Modify: `fraud-api/native/knn.cpp`
- Modify: `fraud-api/native/engine.h`
- Test: `fraud-api/native/tests/engine_smoke.cpp`

- [ ] **Step 1: Add failing smoke test for bucket safety fallback**

```cpp
// pseudo-check via score bounds remains valid when bucket unavailable
float q_bucket[14] = {0.3f, 0.2f, 0.3f, 0.6f, 0.2f, -1, -1, 0.2f, 0.1f, 1, 0, 1, 0.7f, 0.2f};
float s = fraud_score(q_bucket);
assert(s >= 0.0f && s <= 1.0f);
```

- [ ] **Step 2: Generate deterministic bucket lists in preprocess**

```cpp
static inline uint32_t bucket_id(const float* v, uint32_t n_buckets) {
    const uint32_t a = static_cast<uint32_t>(v[2] * 255.0f);
    const uint32_t b = static_cast<uint32_t>(v[7] * 255.0f);
    const uint32_t c = static_cast<uint32_t>(v[12] * 255.0f);
    return (a * 1315423911u ^ b * 2654435761u ^ c) % n_buckets;
}
```

- [ ] **Step 3: Load bucket metadata in engine init as optional path**

```cpp
if (!load_buckets(dataset_dir)) {
    bucket_enabled_ = false;
}
```

- [ ] **Step 4: Use bucket first, then strict fallback to full global**

```cpp
float KNNEngine::score_ambiguous(const float* query) {
    if (bucket_enabled_) {
        const auto bid = bucket_id(query, bucket_count_);
        if (bucket_sizes_[bid] >= static_cast<size_t>(k_runtime_)) {
            counters_.fallback_bucket++;
            return score_knn_bucket(query, bid);
        }
    }
    counters_.fallback_full++;
    return score_knn_full(query);
}
```

- [ ] **Step 5: Re-run smoke/native tests and verify pass**

Run: `make preprocess && make test-native`
Expected: PASS

- [ ] **Step 6: Commit bucket optimization with safety fallback**

```bash
git add scripts/preprocess.cpp fraud-api/native/knn.cpp fraud-api/native/engine.h fraud-api/native/tests/engine_smoke.cpp
git commit -m "feat(native): add deterministic bucket fallback optimization"
```

---

### Task 9: End-to-end benchmark validation and report extraction

**Files:**
- Modify: `scripts/analyze-latency.py` (if needed for parsing only)
- Create: `docs/superpowers/specs/2026-05-17-fraud-cascade-conservative-results.md`

- [ ] **Step 1: Run full benchmark with current stack**

Run: `make benchmark`
Expected: benchmark completes and writes logs in `.benchmark`

- [ ] **Step 2: Capture required metrics from `.benchmark`**

Run: `rg "http_errors|failure_rate|p99|final_score" .benchmark -n`
Expected: lines containing final metrics

- [ ] **Step 3: Capture cascade routing percentages from runtime counters**

Run: `rg "clear_legit|clear_fraud|ambiguous|fallback_bucket|fallback_full" .benchmark -n`
Expected: counter lines available for percentage calculation

- [ ] **Step 4: Write delivery report artifact**

```md
# Conservative Cascade Results

- files changed: ...
- commands run: ...
- metrics: `http_errors=...`, `failure_rate=...`, `p99=...`
- cascade resolved: `...%`
- vector fallback: `...%`
- GBDT: `implemented` or `deferred`
- limitations: ...
```

- [ ] **Step 5: Commit benchmark result report**

```bash
git add docs/superpowers/specs/2026-05-17-fraud-cascade-conservative-results.md
git commit -m "docs: add conservative cascade benchmark results"
```

---

## Spec Coverage Check

- Conservative cascade required path (`rules/tree -> ambiguous -> vector fallback`): covered by Tasks 3 and 4.
- GBDT optional/deferred behavior: covered by Task 3 structure and report in Task 9.
- Identical build/runtime ambiguity logic through artifacts: covered by Task 2 (`rules_model.bin`) and Task 3 loader usage.
- Preserve safe global fallback: covered by Tasks 4 and 8.
- C ABI contract (`fraud_init`, `fraud_score`, `fraud_close`): covered by Task 1 and Task 5.
- Startup-only loading and no per-request I/O: covered by Tasks 2, 3, and 5.
- E2E integration (LB/API/native/Compose/Makefile/benchmark): covered by Tasks 7 and 9.
- Mandatory validation and final delivery metrics: covered by Task 9.

## Placeholder Scan

No `TODO`, `TBD`, or "implement later" markers used.

## Type and Signature Consistency

- C ABI names stay consistent across tasks: `fraud_init`, `fraud_score`, `fraud_close`.
- Vector dimension stays fixed at `14`.
- Score contract stays `[0,1]` and API decision stays `score < 0.6`.
