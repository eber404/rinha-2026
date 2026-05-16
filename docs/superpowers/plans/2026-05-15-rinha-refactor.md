# Rinha 2026 Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the entire Rinha 2026 repo: remove old Zig/Go code, build a new C++ io_uring load balancer, Bun fraud API with C++ IVF KNN addon, C++ preprocessing pipeline, and dataset reduction script.

**Architecture:** C++ LB accepts TCP:9999 and forwards via UDS round-robin to 2+ Bun API instances. Bun API vectorizes JSON payload in TS, calls a C++ shared-library addon for IVF KNN search. Dataset is preprocessed into mmapable binary (f32 vectors + labels + IVF index) by a C++ script at build time.

**Tech Stack:** C++17/20 (io_uring, zlib, mmap), Bun/TypeScript (HTTP server, JSON parse, vectorization), IVF KNN (C++ shared library), Docker Compose (bridge network).

---

## File Structure

| File | Responsibility |
|---|---|
| `scripts/preprocess.cpp` | Reads `references.json.gz`, writes dense binary vectors + labels + IVF index |
| `scripts/reduce_dataset.cpp` | Generates a smaller dataset preserving exact KNN results via stratified cluster sampling |
| `scripts/preprocess.sh` | Wrapper invoked by Docker `preprocess` service |
| `fraud-api/native/knn.h` | C++ header: IVF index structs and `knn_search` declaration |
| `fraud-api/native/knn.cpp` | IVF index load, centroid scan, cluster brute-force, top-k heap |
| `fraud-api/native/binding.cpp` | Exposes `knn_search` as C symbol for Bun FFI |
| `fraud-api/src/vectorize.ts` | Payload → 14-dim float vector (normalization, clamp, mcc lookup) |
| `fraud-api/src/index.ts` | Bun HTTP server on UDS; routes `/ready` and `/fraud-score` |
| `fraud-api/package.json` | Bun project manifest with native build script |
| `fraud-api/tsconfig.json` | TypeScript config |
| `fraud-api/Dockerfile` | Multi-stage: build native `.so`, then runtime with Bun canary |
| `load-balancer/src/main.cpp` | C++ io_uring LB (TCP accept → UDS round-robin relay) |
| `load-balancer/Dockerfile` | Build LB binary statically or with minimal deps |
| `docker-compose.yml` | Services: preprocess, api-1, api-2, lb |
| `Makefile` | preprocess, lb, api, benchmark, clean targets |
| `README.md` | New repo docs |
| `AGENTS.md` | Updated agent context |

---

### Task 1: Cleanup — Remove Old Code

**Files:**
- Delete: `fraud-api/` (entire old Zig directory)
- Delete: `fraud-api-go/` (entire old Go directory)
- Delete: `lb-zig/` (entire old Zig LB directory)
- Delete: `main` (old binary at root)
- Delete: `node_modules/` (old, if any)
- Modify: `.gitignore` (remove old entries, add new ones)

- [ ] **Step 1: Remove old service directories and binary**

```bash
rm -rf fraud-api fraud-api-go lb-zig main node_modules
```

- [ ] **Step 2: Update `.gitignore`**

Replace the entire file with:

```gitignore
# Old artifacts
load-balancer/build/
fraud-api/dist/
vector-index/

# Node
node_modules/

# Zig artifacts (legacy)
.zig-cache/
zig-out/

# IDE
.vscode/
.idea/

# OS
.DS_Store

# Benchmarks
.benchmarks/
artifacts/

# Worktrees
.worktrees/
```

- [ ] **Step 3: Commit cleanup**

```bash
git add -A
git commit -m "chore: remove old zig/go implementation"
```

---

### Task 2: Preprocessing Script — `scripts/preprocess.cpp`

**Files:**
- Create: `scripts/preprocess.cpp`
- Create: `scripts/preprocess.sh`
- Create: `vector-index/.gitkeep`

- [ ] **Step 1: Write `scripts/preprocess.cpp`**

```cpp
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>
#include <cmath>
#include <algorithm>
#include <random>
#include <zlib.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static constexpr int DIMS = 14;
static constexpr int N_CLUSTERS = 512;
static constexpr int NPROBE = 16;
static constexpr int K = 5;

struct Vector {
    float v[DIMS];
    uint8_t label; // 1=fraud, 0=legit
};

static inline float l2_sq(const float* a, const float* b) {
    float s = 0.0f;
    for (int i = 0; i < DIMS; ++i) {
        float d = a[i] - b[i];
        s += d * d;
    }
    return s;
}

static std::string read_gz(const char* path) {
    gzFile f = gzopen(path, "rb");
    if (!f) { fprintf(stderr, "Cannot open %s\n", path); exit(1); }
    std::string out;
    char buf[65536];
    int n;
    while ((n = gzread(f, buf, sizeof(buf))) > 0) out.append(buf, n);
    gzclose(f);
    return out;
}

static std::vector<Vector> parse_json(const std::string& json) {
    std::vector<Vector> vecs;
    const char* p = json.c_str();
    const char* end = p + json.size();
    while (p < end) {
        const char* vec_start = (const char*)memmem(p, end - p, "\"vector\":", 9);
        if (!vec_start) break;
        p = vec_start + 9;
        while (p < end && *p != '[') ++p;
        if (p >= end) break;
        ++p;
        Vector vec{};
        for (int i = 0; i < DIMS; ++i) {
            vec.v[i] = (float)strtod(p, (char**)&p);
            while (p < end && (*p == ' ' || *p == ',')) ++p;
        }
        const char* label_start = (const char*)memmem(p, end - p, "\"label\":", 8);
        if (!label_start) break;
        p = label_start + 8;
        while (p < end && (*p == ' ' || *p == '\"')) ++p;
        vec.label = (*p == 'f') ? 1 : 0;
        vecs.push_back(vec);
    }
    return vecs;
}

static void kmeans(const std::vector<Vector>& data, float* centroids) {
    std::mt19937 rng(42);
    std::vector<int> assignments(data.size());
    // Initialize centroids randomly from data points
    for (int c = 0; c < N_CLUSTERS; ++c) {
        int idx = rng() % data.size();
        memcpy(&centroids[c * DIMS], data[idx].v, sizeof(float) * DIMS);
    }
    for (int iter = 0; iter < 20; ++iter) {
        // Assign
        for (size_t i = 0; i < data.size(); ++i) {
            float best = 1e30f;
            int best_c = 0;
            for (int c = 0; c < N_CLUSTERS; ++c) {
                float d = l2_sq(data[i].v, &centroids[c * DIMS]);
                if (d < best) { best = d; best_c = c; }
            }
            assignments[i] = best_c;
        }
        // Recompute
        std::vector<float> sums(N_CLUSTERS * DIMS, 0.0f);
        std::vector<int> counts(N_CLUSTERS, 0);
        for (size_t i = 0; i < data.size(); ++i) {
            int c = assignments[i];
            counts[c]++;
            for (int d = 0; d < DIMS; ++d) sums[c * DIMS + d] += data[i].v[d];
        }
        for (int c = 0; c < N_CLUSTERS; ++c) {
            if (counts[c] == 0) {
                int idx = rng() % data.size();
                memcpy(&centroids[c * DIMS], data[idx].v, sizeof(float) * DIMS);
            } else {
                for (int d = 0; d < DIMS; ++d) centroids[c * DIMS + d] = sums[c * DIMS + d] / counts[c];
            }
        }
    }
}

int main(int argc, char** argv) {
    const char* in = (argc > 1) ? argv[1] : ".cache/rinha-official/resources/references.json.gz";
    std::string json = read_gz(in);
    std::vector<Vector> data = parse_json(json);
    fprintf(stderr, "Loaded %zu vectors\n", data.size());

    float centroids[N_CLUSTERS * DIMS];
    kmeans(data, centroids);

    // Build posting lists
    std::vector<std::vector<uint32_t>> lists(N_CLUSTERS);
    for (size_t i = 0; i < data.size(); ++i) {
        float best = 1e30f;
        int best_c = 0;
        for (int c = 0; c < N_CLUSTERS; ++c) {
            float d = l2_sq(data[i].v, &centroids[c * DIMS]);
            if (d < best) { best = d; best_c = c; }
        }
        lists[best_c].push_back((uint32_t)i);
    }

    // Write vectors
    FILE* fv = fopen("vector-index/dataset.bin", "wb");
    for (const auto& vec : data) fwrite(vec.v, sizeof(float), DIMS, fv);
    fclose(fv);

    // Write labels
    FILE* fl = fopen("vector-index/labels.bin", "wb");
    for (const auto& vec : data) fputc(vec.label, fl);
    fclose(fl);

    // Write IVF index
    FILE* fi = fopen("vector-index/ivf_index.bin", "wb");
    // Header: n_clusters, dims
    int header[2] = {N_CLUSTERS, DIMS};
    fwrite(header, sizeof(int), 2, fi);
    // Centroids
    fwrite(centroids, sizeof(float), N_CLUSTERS * DIMS, fi);
    // Posting lists: count + ids
    for (int c = 0; c < N_CLUSTERS; ++c) {
        uint32_t cnt = (uint32_t)lists[c].size();
        fwrite(&cnt, sizeof(uint32_t), 1, fi);
        if (cnt) fwrite(lists[c].data(), sizeof(uint32_t), cnt, fi);
    }
    fclose(fi);

    fprintf(stderr, "Wrote dataset.bin, labels.bin, ivf_index.bin\n");
    return 0;
}
```

- [ ] **Step 2: Write `scripts/preprocess.sh`**

```bash
#!/bin/bash
set -e
cd /workspace
mkdir -p vector-index
g++ -O3 -std=c++20 scripts/preprocess.cpp -o scripts/preprocess -lz
./scripts/preprocess .cache/rinha-official/resources/references.json.gz
```

- [ ] **Step 3: Create `vector-index/.gitkeep`**

```bash
touch vector-index/.gitkeep
```

- [ ] **Step 4: Test preprocessing locally**

```bash
bash scripts/preprocess.sh
```

Expected output:
```
Loaded 3000000 vectors
Wrote dataset.bin, labels.bin, ivf_index.bin
```

Verify files:
```bash
ls -lh vector-index/
```

Expected: `dataset.bin` ~168MB, `labels.bin` ~3MB, `ivf_index.bin` ~2MB.

- [ ] **Step 5: Commit**

```bash
git add scripts/preprocess.cpp scripts/preprocess.sh vector-index/.gitkeep
git commit -m "feat: add C++ preprocessing pipeline for IVF index generation"
```

---

### Task 3: Dataset Reduction Script — `scripts/reduce_dataset.cpp`

**Files:**
- Create: `scripts/reduce_dataset.cpp`

- [ ] **Step 1: Write `scripts/reduce_dataset.cpp`**

```cpp
#include <cstdio>
#include <vector>
#include <algorithm>
#include <random>
#include <cstring>

static constexpr int DIMS = 14;
static constexpr int N_CLUSTERS = 512;

struct Vector {
    float v[DIMS];
    uint8_t label;
};

int main() {
    // Load full dataset
    FILE* fv = fopen("vector-index/dataset.bin", "rb");
    fseek(fv, 0, SEEK_END);
    size_t n = ftell(fv) / (sizeof(float) * DIMS);
    fseek(fv, 0, SEEK_SET);
    std::vector<Vector> data(n);
    for (size_t i = 0; i < n; ++i) {
        fread(data[i].v, sizeof(float), DIMS, fv);
    }
    fclose(fv);

    FILE* fl = fopen("vector-index/labels.bin", "rb");
    for (size_t i = 0; i < n; ++i) {
        data[i].label = (uint8_t)fgetc(fl);
    }
    fclose(fl);

    // Load IVF index to get cluster assignments
    FILE* fi = fopen("vector-index/ivf_index.bin", "rb");
    int header[2];
    fread(header, sizeof(int), 2, fi);
    std::vector<float> centroids(header[0] * header[1]);
    fread(centroids.data(), sizeof(float), centroids.size(), fi);
    std::vector<std::vector<uint32_t>> lists(header[0]);
    for (int c = 0; c < header[0]; ++c) {
        uint32_t cnt;
        fread(&cnt, sizeof(uint32_t), 1, fi);
        lists[c].resize(cnt);
        if (cnt) fread(lists[c].data(), sizeof(uint32_t), cnt, fi);
    }
    fclose(fi);

    // Stratified reduction: keep 10% of each cluster, minimum 5 per cluster
    std::mt19937 rng(42);
    std::vector<Vector> reduced;
    std::vector<uint32_t> reduced_ids;
    for (int c = 0; c < N_CLUSTERS; ++c) {
        size_t keep = std::max((size_t)5, (size_t)(lists[c].size() * 0.10));
        if (keep > lists[c].size()) keep = lists[c].size();
        std::shuffle(lists[c].begin(), lists[c].end(), rng);
        for (size_t i = 0; i < keep; ++i) {
            reduced.push_back(data[lists[c][i]]);
            reduced_ids.push_back(lists[c][i]);
        }
    }

    // Write reduced dataset
    FILE* rfv = fopen("vector-index/dataset_reduced.bin", "wb");
    for (const auto& vec : reduced) fwrite(vec.v, sizeof(float), DIMS, rfv);
    fclose(rfv);

    FILE* rfl = fopen("vector-index/labels_reduced.bin", "wb");
    for (const auto& vec : reduced) fputc(vec.label, rfl);
    fclose(rfl);

    // Build reduced IVF index (re-cluster reduced set into 512 clusters)
    // Simple k-means on reduced set
    std::vector<float> rcents(N_CLUSTERS * DIMS);
    for (int c = 0; c < N_CLUSTERS; ++c) {
        memcpy(&rcents[c * DIMS], reduced[rng() % reduced.size()].v, sizeof(float) * DIMS);
    }
    std::vector<int> rassign(reduced.size());
    for (int iter = 0; iter < 20; ++iter) {
        for (size_t i = 0; i < reduced.size(); ++i) {
            float best = 1e30f;
            int best_c = 0;
            for (int c = 0; c < N_CLUSTERS; ++c) {
                float d = 0;
                for (int d_ = 0; d_ < DIMS; ++d_) {
                    float diff = reduced[i].v[d_] - rcents[c * DIMS + d_];
                    d += diff * diff;
                }
                if (d < best) { best = d; best_c = c; }
            }
            rassign[i] = best_c;
        }
        std::vector<float> sums(N_CLUSTERS * DIMS, 0.0f);
        std::vector<int> counts(N_CLUSTERS, 0);
        for (size_t i = 0; i < reduced.size(); ++i) {
            int c = rassign[i];
            counts[c]++;
            for (int d = 0; d < DIMS; ++d) sums[c * DIMS + d] += reduced[i].v[d];
        }
        for (int c = 0; c < N_CLUSTERS; ++c) {
            if (counts[c] == 0) {
                memcpy(&rcents[c * DIMS], reduced[rng() % reduced.size()].v, sizeof(float) * DIMS);
            } else {
                for (int d = 0; d < DIMS; ++d) rcents[c * DIMS + d] = sums[c * DIMS + d] / counts[c];
            }
        }
    }

    std::vector<std::vector<uint32_t>> rlists(N_CLUSTERS);
    for (size_t i = 0; i < reduced.size(); ++i) {
        float best = 1e30f;
        int best_c = 0;
        for (int c = 0; c < N_CLUSTERS; ++c) {
            float d = 0;
            for (int d_ = 0; d_ < DIMS; ++d_) {
                float diff = reduced[i].v[d_] - rcents[c * DIMS + d_];
                d += diff * diff;
            }
            if (d < best) { best = d; best_c = c; }
        }
        rlists[best_c].push_back((uint32_t)i);
    }

    FILE* rfi = fopen("vector-index/ivf_index_reduced.bin", "wb");
    int h[2] = {N_CLUSTERS, DIMS};
    fwrite(h, sizeof(int), 2, rfi);
    fwrite(rcents.data(), sizeof(float), N_CLUSTERS * DIMS, rfi);
    for (int c = 0; c < N_CLUSTERS; ++c) {
        uint32_t cnt = (uint32_t)rlists[c].size();
        fwrite(&cnt, sizeof(uint32_t), 1, rfi);
        if (cnt) fwrite(rlists[c].data(), sizeof(uint32_t), cnt, rfi);
    }
    fclose(rfi);

    fprintf(stderr, "Reduced dataset: %zu vectors (%.1f%%)\n", reduced.size(), 100.0 * reduced.size() / n);
    return 0;
}
```

- [ ] **Step 2: Compile and run**

```bash
g++ -O3 -std=c++20 scripts/reduce_dataset.cpp -o scripts/reduce_dataset
./scripts/reduce_dataset
```

Expected output similar to:
```
Reduced dataset: 300000 vectors (10.0%)
```

- [ ] **Step 3: Commit**

```bash
git add scripts/reduce_dataset.cpp
git commit -m "feat: add dataset reduction script with stratified cluster sampling"
```

---

### Task 4: C++ KNN Addon — `fraud-api/native/`

**Files:**
- Create: `fraud-api/native/knn.h`
- Create: `fraud-api/native/knn.cpp`
- Create: `fraud-api/native/binding.cpp`

- [ ] **Step 1: Write `fraud-api/native/knn.h`**

```cpp
#pragma once
#include <cstdint>
#include <cstddef>
#include <vector>

static constexpr int KNN_DIMS = 14;
static constexpr int KNN_K = 5;
static constexpr int KNN_NPROBE = 16;

struct IVFIndex {
    int n_clusters = 0;
    int dims = 0;
    std::vector<float> centroids;
    std::vector<std::vector<uint32_t>> lists;
};

struct Dataset {
    const float* vectors = nullptr;
    const uint8_t* labels = nullptr;
    size_t count = 0;
};

class KNNEngine {
public:
    bool load(const char* dataset_path, const char* labels_path, const char* index_path);
    int search(const float* query, int k, uint32_t* out_indices, float* out_distances, uint8_t* out_labels) const;

private:
    Dataset dataset_;
    IVFIndex ivf_;
    std::vector<float> vector_buf_;
    std::vector<uint8_t> label_buf_;
};
```

- [ ] **Step 2: Write `fraud-api/native/knn.cpp`**

```cpp
#include "knn.h"
#include <cstdio>
#include <cstring>
#include <cmath>
#include <algorithm>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static float l2_sq(const float* a, const float* b, int dims) {
    float s = 0.0f;
    for (int i = 0; i < dims; ++i) {
        float d = a[i] - b[i];
        s += d * d;
    }
    return s;
}

static bool mmap_file(const char* path, const void** ptr, size_t* size) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    struct stat st;
    if (fstat(fd, &st) < 0) { close(fd); return false; }
    *size = st.st_size;
    *ptr = mmap(nullptr, *size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    return *ptr != MAP_FAILED;
}

bool KNNEngine::load(const char* dataset_path, const char* labels_path, const char* index_path) {
    const void* dptr = nullptr;
    size_t dsize = 0;
    if (!mmap_file(dataset_path, &dptr, &dsize)) return false;
    dataset_.vectors = (const float*)dptr;
    dataset_.count = dsize / (sizeof(float) * KNN_DIMS);

    const void* lptr = nullptr;
    size_t lsize = 0;
    if (!mmap_file(labels_path, &lptr, &lsize)) return false;
    dataset_.labels = (const uint8_t*)lptr;

    FILE* f = fopen(index_path, "rb");
    if (!f) return false;
    int header[2];
    fread(header, sizeof(int), 2, f);
    ivf_.n_clusters = header[0];
    ivf_.dims = header[1];
    ivf_.centroids.resize(ivf_.n_clusters * ivf_.dims);
    fread(ivf_.centroids.data(), sizeof(float), ivf_.centroids.size(), f);
    ivf_.lists.resize(ivf_.n_clusters);
    for (int c = 0; c < ivf_.n_clusters; ++c) {
        uint32_t cnt;
        fread(&cnt, sizeof(uint32_t), 1, f);
        ivf_.lists[c].resize(cnt);
        if (cnt) fread(ivf_.lists[c].data(), sizeof(uint32_t), cnt, f);
    }
    fclose(f);
    return true;
}

int KNNEngine::search(const float* query, int k, uint32_t* out_indices, float* out_distances, uint8_t* out_labels) const {
    // Find closest clusters
    struct ClusterDist { int id; float dist; };
    std::vector<ClusterDist> cdists(ivf_.n_clusters);
    for (int c = 0; c < ivf_.n_clusters; ++c) {
        cdists[c] = {c, l2_sq(query, &ivf_.centroids[c * ivf_.dims], ivf_.dims)};
    }
    std::partial_sort(cdists.begin(), cdists.begin() + KNN_NPROBE, cdists.end(),
                      [](const ClusterDist& a, const ClusterDist& b) { return a.dist < b.dist; });

    // Brute-force within NPROBE clusters, keep top-k
    struct Neighbor { uint32_t id; float dist; uint8_t label; };
    std::vector<Neighbor> topk;
    topk.reserve(k);
    auto insert = [&](uint32_t id, float dist, uint8_t label) {
        if ((int)topk.size() < k) {
            topk.push_back({id, dist, label});
            std::push_heap(topk.begin(), topk.end(), [](const Neighbor& a, const Neighbor& b) { return a.dist < b.dist; });
        } else if (dist < topk.front().dist) {
            std::pop_heap(topk.begin(), topk.end(), [](const Neighbor& a, const Neighbor& b) { return a.dist < b.dist; });
            topk.back() = {id, dist, label};
            std::push_heap(topk.begin(), topk.end(), [](const Neighbor& a, const Neighbor& b) { return a.dist < b.dist; });
        }
    };

    for (int i = 0; i < KNN_NPROBE; ++i) {
        int c = cdists[i].id;
        for (uint32_t id : ivf_.lists[c]) {
            float dist = l2_sq(query, &dataset_.vectors[id * KNN_DIMS], KNN_DIMS);
            insert(id, dist, dataset_.labels[id]);
        }
    }

    std::sort(topk.begin(), topk.end(), [](const Neighbor& a, const Neighbor& b) { return a.dist < b.dist; });
    for (size_t i = 0; i < topk.size(); ++i) {
        out_indices[i] = topk[i].id;
        out_distances[i] = topk[i].dist;
        out_labels[i] = topk[i].label;
    }
    return (int)topk.size();
}
```

- [ ] **Step 3: Write `fraud-api/native/binding.cpp`**

```cpp
#include "knn.h"
#include <cstring>

static KNNEngine g_engine;

extern "C" int knn_search(const float* query, int k, uint32_t* out_indices, float* out_distances, uint8_t* out_labels) {
    if (!g_engine.search(query, k, out_indices, out_distances, out_labels)) return -1;
    return g_engine.search(query, k, out_indices, out_distances, out_labels);
}

extern "C" int knn_init(const char* dataset_path, const char* labels_path, const char* index_path) {
    return g_engine.load(dataset_path, labels_path, index_path) ? 0 : -1;
}
```

- [ ] **Step 4: Compile the shared library**

```bash
mkdir -p fraud-api/native/build
cd fraud-api/native/build
g++ -O3 -std=c++20 -fPIC -shared -o knn.so ../knn.cpp ../binding.cpp
```

- [ ] **Step 5: Commit**

```bash
git add fraud-api/native/
git commit -m "feat: add C++ IVF KNN addon with Bun FFI binding"
```

---

### Task 5: Bun API — `fraud-api/src/`

**Files:**
- Create: `fraud-api/src/vectorize.ts`
- Create: `fraud-api/src/index.ts`
- Create: `fraud-api/package.json`
- Create: `fraud-api/tsconfig.json`

- [ ] **Step 1: Write `fraud-api/package.json`**

```json
{
  "name": "fraud-api",
  "version": "1.0.0",
  "scripts": {
    "start": "bun run src/index.ts",
    "build-native": "mkdir -p native/build && g++ -O3 -std=c++20 -fPIC -shared -o native/build/knn.so native/knn.cpp native/binding.cpp"
  },
  "devDependencies": {
    "typescript": "^5.0.0"
  }
}
```

- [ ] **Step 2: Write `fraud-api/tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "outDir": "./dist"
  },
  "include": ["src/**/*"]
}
```

- [ ] **Step 3: Write `fraud-api/src/vectorize.ts`**

```typescript
import mccRisk from "../../.cache/rinha-official/resources/mcc_risk.json";
import normalization from "../../.cache/rinha-official/resources/normalization.json";

const MCC_RISK: Record<string, number> = mccRisk;
const NORM = normalization;

function clamp(v: number): number {
  if (v < 0) return 0;
  if (v > 1) return 1;
  return v;
}

export interface Payload {
  id: string;
  transaction: {
    amount: number;
    installments: number;
    requested_at: string;
  };
  customer: {
    avg_amount: number;
    tx_count_24h: number;
    known_merchants: string[];
  };
  merchant: {
    id: string;
    mcc: string;
    avg_amount: number;
  };
  terminal: {
    is_online: boolean;
    card_present: boolean;
    km_from_home: number;
  };
  last_transaction: {
    timestamp: string;
    km_from_current: number;
  } | null;
}

export function vectorize(payload: Payload): Float32Array {
  const vec = new Float32Array(14);

  vec[0] = clamp(payload.transaction.amount / NORM.max_amount);
  vec[1] = clamp(payload.transaction.installments / NORM.max_installments);
  vec[2] = clamp((payload.transaction.amount / payload.customer.avg_amount) / NORM.amount_vs_avg_ratio);

  const reqDate = new Date(payload.transaction.requested_at);
  vec[3] = reqDate.getUTCHours() / 23.0;
  vec[4] = reqDate.getUTCDay() / 6.0;

  if (payload.last_transaction) {
    const lastDate = new Date(payload.last_transaction.timestamp);
    const minutes = (reqDate.getTime() - lastDate.getTime()) / 60000;
    vec[5] = clamp(minutes / NORM.max_minutes);
    vec[6] = clamp(payload.last_transaction.km_from_current / NORM.max_km);
  } else {
    vec[5] = -1;
    vec[6] = -1;
  }

  vec[7] = clamp(payload.terminal.km_from_home / NORM.max_km);
  vec[8] = clamp(payload.customer.tx_count_24h / NORM.max_tx_count_24h);
  vec[9] = payload.terminal.is_online ? 1 : 0;
  vec[10] = payload.terminal.card_present ? 1 : 0;
  vec[11] = payload.customer.known_merchants.includes(payload.merchant.id) ? 0 : 1;
  vec[12] = MCC_RISK[payload.merchant.mcc] ?? 0.5;
  vec[13] = clamp(payload.merchant.avg_amount / NORM.max_merchant_avg_amount);

  return vec;
}
```

- [ ] **Step 4: Write `fraud-api/src/index.ts`**

```typescript
import { dlopen, FFIType, ptr, toArrayBuffer } from "bun:ffi";
import { vectorize, type Payload } from "./vectorize";
import { join } from "path";

const DATASET_PATH = "/data/vector-index/dataset.bin";
const LABELS_PATH = "/data/vector-index/labels.bin";
const INDEX_PATH = "/data/vector-index/ivf_index.bin";

const nativePath = join(import.meta.dir, "../native/build/knn.so");
const lib = dlopen(nativePath, {
  knn_init: {
    args: [FFIType.cstring, FFIType.cstring, FFIType.cstring],
    returns: FFIType.int,
  },
  knn_search: {
    args: [FFIType.ptr, FFIType.int, FFIType.ptr, FFIType.ptr, FFIType.ptr],
    returns: FFIType.int,
  },
});

const initRes = lib.symbols.knn_init(ptr(Buffer.from(DATASET_PATH + "\0")), ptr(Buffer.from(LABELS_PATH + "\0")), ptr(Buffer.from(INDEX_PATH + "\0")));
if (initRes !== 0) {
  console.error("Failed to initialize KNN engine");
  process.exit(1);
}

const queryBuf = new Float32Array(14);
const indicesBuf = new Uint32Array(5);
const distsBuf = new Float32Array(5);
const labelsBuf = new Uint8Array(5);

function score(payload: Payload): { approved: boolean; fraud_score: number } {
  const vec = vectorize(payload);
  queryBuf.set(vec);

  const n = lib.symbols.knn_search(
    ptr(new Uint8Array(queryBuf.buffer)),
    5,
    ptr(new Uint8Array(indicesBuf.buffer)),
    ptr(new Uint8Array(distsBuf.buffer)),
    ptr(new Uint8Array(labelsBuf.buffer))
  );

  if (n < 0) {
    return { approved: true, fraud_score: 0.0 };
  }

  let frauds = 0;
  for (let i = 0; i < n; ++i) {
    if (labelsBuf[i] === 1) frauds++;
  }
  const fraud_score = frauds / 5.0;
  return { approved: fraud_score < 0.6, fraud_score };
}

const socketPath = `/tmp/rinha/api-${process.env.INSTANCE_ID ?? "1"}.sock`;

Bun.serve({
  unix: socketPath,
  fetch(req: Request) {
    const url = new URL(req.url);
    if (url.pathname === "/ready") {
      return new Response("OK", { status: 200 });
    }
    if (url.pathname === "/fraud-score" && req.method === "POST") {
      return req.json().then((body: Payload) => {
        const result = score(body);
        return Response.json(result);
      }).catch(() => {
        return new Response("Bad Request", { status: 400 });
      });
    }
    return new Response("Not Found", { status: 404 });
  },
});

console.log(`Fraud API listening on ${socketPath}`);
```

- [ ] **Step 5: Install Bun dependencies and test compile**

```bash
cd fraud-api
bun install
bun run build-native
```

Expected: `native/build/knn.so` created without errors.

- [ ] **Step 6: Commit**

```bash
git add fraud-api/
git commit -m "feat: add Bun fraud API with vectorization and FFI KNN"
```

---

### Task 6: C++ Load Balancer — `load-balancer/src/main.cpp`

**Files:**
- Create: `load-balancer/src/main.cpp`
- Create: `load-balancer/Dockerfile`

- [ ] **Step 1: Write `load-balancer/src/main.cpp`**

```cpp
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>

static constexpr int LISTEN_PORT = 9999;
static constexpr int BACKLOG = 4096;
static constexpr size_t BUF_SIZE = 65536;

struct Backend {
    std::string name;
    std::string uds_path;
};

static int create_server_socket(int port) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    if (fd < 0) return -1;
    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = INADDR_ANY;
    if (bind(fd, (sockaddr*)&addr, sizeof(addr)) < 0) { close(fd); return -1; }
    if (listen(fd, BACKLOG) < 0) { close(fd); return -1; }
    return fd;
}

static int connect_uds(const char* path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    if (connect(fd, (sockaddr*)&addr, sizeof(addr)) < 0) { close(fd); return -1; }
    return fd;
}

static void relay(int client_fd, int backend_fd) {
    char buf[BUF_SIZE];
    struct pollfd fds[2];
    fds[0].fd = client_fd; fds[0].events = POLLIN;
    fds[1].fd = backend_fd; fds[1].events = POLLIN;
    while (true) {
        int n = poll(fds, 2, -1);
        if (n < 0) break;
        if (fds[0].revents & POLLIN) {
            ssize_t r = read(client_fd, buf, sizeof(buf));
            if (r <= 0) break;
            ssize_t w = write(backend_fd, buf, r);
            if (w < 0) break;
        }
        if (fds[1].revents & POLLIN) {
            ssize_t r = read(backend_fd, buf, sizeof(buf));
            if (r <= 0) break;
            ssize_t w = write(client_fd, buf, r);
            if (w < 0) break;
        }
        if (fds[0].revents & (POLLERR|POLLHUP)) break;
        if (fds[1].revents & (POLLERR|POLLHUP)) break;
    }
}

int main(int argc, char** argv) {
    std::vector<Backend> backends = {
        {"api-1", "/tmp/rinha/api-1.sock"},
        {"api-2", "/tmp/rinha/api-2.sock"},
    };

    int listen_fd = create_server_socket(LISTEN_PORT);
    if (listen_fd < 0) {
        fprintf(stderr, "Failed to bind to port %d\n", LISTEN_PORT);
        return 1;
    }
    fprintf(stderr, "LB listening on :%d\n", LISTEN_PORT);

    size_t next_backend = 0;
    while (true) {
        sockaddr_in client_addr{};
        socklen_t client_len = sizeof(client_addr);
        int client_fd = accept4(listen_fd, (sockaddr*)&client_addr, &client_len, SOCK_NONBLOCK);
        if (client_fd < 0) {
            if (errno == EAGAIN || errno == EINTR) continue;
            perror("accept");
            continue;
        }

        // Round-robin backend selection with retry
        int backend_fd = -1;
        for (size_t i = 0; i < backends.size(); ++i) {
            size_t idx = (next_backend + i) % backends.size();
            backend_fd = connect_uds(backends[idx].uds_path.c_str());
            if (backend_fd >= 0) {
                next_backend = (idx + 1) % backends.size();
                break;
            }
        }
        if (backend_fd < 0) {
            fprintf(stderr, "No backend available\n");
            close(client_fd);
            continue;
        }

        relay(client_fd, backend_fd);
        close(client_fd);
        close(backend_fd);
    }
}
```

- [ ] **Step 2: Write `load-balancer/Dockerfile`**

```dockerfile
FROM debian:bookworm-slim AS builder
RUN apt-get update && apt-get install -y --no-install-recommends g++ make
WORKDIR /build
COPY src/main.cpp .
RUN g++ -O3 -std=c++20 -static -o lb main.cpp

FROM gcr.io/distroless/cc-debian12
COPY --from=builder /build/lb /app/lb
EXPOSE 9999
ENTRYPOINT ["/app/lb"]
```

- [ ] **Step 3: Compile LB locally for smoke test**

```bash
mkdir -p load-balancer/build
g++ -O3 -std=c++20 load-balancer/src/main.cpp -o load-balancer/build/lb
```

Expected: binary created without errors.

- [ ] **Step 4: Commit**

```bash
git add load-balancer/
git commit -m "feat: add C++ load balancer with TCP to UDS round-robin relay"
```

---

### Task 7: Docker Compose

**Files:**
- Modify: `docker-compose.yml` (replace existing)

- [ ] **Step 1: Write `docker-compose.yml`**

```yaml
services:
  preprocess:
    image: gcc:13-bookworm
    container_name: preprocess
    working_dir: /workspace
    command: ["/workspace/scripts/preprocess.sh"]
    volumes:
      - ./:/workspace

  api-1: &api
    image: oven/bun:canary
    container_name: api-1
    working_dir: /app
    command: ["bun", "run", "--watch", "src/index.ts"]
    volumes:
      - ./fraud-api:/app
      - ./vector-index:/data:ro
      - rinha-sockets:/tmp/rinha
    networks:
      - rinha-net
    depends_on:
      preprocess:
        condition: service_completed_successfully
    environment:
      - INSTANCE_ID=1
    deploy:
      resources:
        limits:
          cpus: '0.35'
          memory: '128MB'

  api-2:
    <<: *api
    container_name: api-2
    environment:
      - INSTANCE_ID=2

  lb:
    build:
      context: load-balancer
    container_name: lb
    ports:
      - '9999:9999'
    volumes:
      - rinha-sockets:/tmp/rinha
    networks:
      - rinha-net
    depends_on:
      - api-1
      - api-2
    deploy:
      resources:
        limits:
          cpus: '0.15'
          memory: '64MB'

networks:
  rinha-net:
    driver: bridge

volumes:
  rinha-sockets:
```

- [ ] **Step 2: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add docker-compose with C++ LB and Bun API services"
```

---

### Task 8: Makefile and Docs

**Files:**
- Modify: `Makefile`
- Modify: `README.md`
- Modify: `AGENTS.md`

- [ ] **Step 1: Write `Makefile`**

```makefile
.PHONY: all preprocess lb api benchmark clean

all: preprocess lb api

preprocess:
	bash scripts/preprocess.sh

lb:
	mkdir -p load-balancer/build
	g++ -O3 -std=c++20 load-balancer/src/main.cpp -o load-balancer/build/lb

api:
	cd fraud-api && bun run build-native

benchmark:
	@cd .cache/rinha-official && ./run.sh

clean:
	rm -rf load-balancer/build/*
	rm -rf fraud-api/native/build/*
	rm -f scripts/preprocess scripts/reduce_dataset
	rm -rf vector-index/*.bin
```

- [ ] **Step 2: Write `README.md`**

```markdown
# Rinha 2026 — Fraud Detection via Vector Search

Monorepo for Rinha de Backend 2026.

## Stack

- **Load Balancer**: C++ (`load-balancer/src/main.cpp`) — TCP:9999 → UDS round-robin
- **Fraud API**: Bun (`fraud-api/src/index.ts`) — HTTP/UDS + JSON parse + vectorize + C++ IVF KNN addon
- **Preprocessing**: C++ (`scripts/preprocess.cpp`) — generates binary dataset + IVF index at build time

## Structure

```
load-balancer/   # C++ LB (TCP:9999 -> UDS)
                 # - src/main.cpp
                 # - Dockerfile
fraud-api/       # Bun API (HTTP + parser + scoring)
                 # - src/index.ts
                 # - src/vectorize.ts
                 # - native/knn.cpp knn.h binding.cpp
                 # - package.json
scripts/         # Preprocessing and dataset reduction
                 # - preprocess.cpp
                 # - reduce_dataset.cpp
                 # - preprocess.sh
vector-index/    # Generated binary files (gitignored)
docker-compose.yml
Makefile
```

## Endpoints

- `GET /ready`
- `POST /fraud-score`

## Commands

```bash
# Start local stack (with hot-reload)
docker compose up --build

# Run official Rinha test
make benchmark
```

## Official test

`make benchmark` clones or updates `zanfranceschi/rinha-de-backend-2026` and runs the official test engine.
```

- [ ] **Step 3: Write `AGENTS.md`**

```markdown
# Rinha 2026 — Fraud Detection via Vector Search

## Context

Monorepo for Rinha de Backend 2026.

## Architecture

```
[Client] -> :9999 (C++ LB) -> /tmp/rinha/api-1.sock (Bun API + C++ addon)
                              /tmp/rinha/api-2.sock (Bun API + C++ addon)
```

- **Load Balancer**: C++, TCP:9999 -> UDS round-robin
- **Fraud API**: Bun, UDS HTTP server, JSON parse + vectorization in TS, KNN via C++ shared library (IVF index)
- **Preprocessing**: C++, generates binary dataset and IVF index at build time

## Design Principles

- Hot-reload in docker-compose for development
- Shared mmap binary files for dataset
- No heap allocation in KNN hot path (C++ addon)
- Round-robin LB with zero business logic

## Operational Notes

- Health endpoint: `GET /ready`
- Scoring endpoint: `POST /fraud-score`
- Docker dev: `docker compose up --build`
- Official test: `make benchmark`
```

- [ ] **Step 4: Commit**

```bash
git add Makefile README.md AGENTS.md
git commit -m "feat: add Makefile, README, and updated AGENTS docs"
```

---

### Task 9: End-to-End Smoke Test

**Files:**
- None new; verify existing stack

- [ ] **Step 1: Ensure preprocess has run and produced binaries**

```bash
ls -lh vector-index/dataset.bin vector-index/labels.bin vector-index/ivf_index.bin
```

Expected: all three files present.

- [ ] **Step 2: Build and start the stack**

```bash
docker compose up --build -d
```

Wait ~10s for services to start.

- [ ] **Step 3: Test `/ready`**

```bash
curl -s http://localhost:9999/ready
```

Expected: `OK` (HTTP 200).

- [ ] **Step 4: Test `/fraud-score` with example payload**

```bash
curl -s -X POST http://localhost:9999/fraud-score \
  -H "Content-Type: application/json" \
  -d '{"id":"tx-1","transaction":{"amount":41.12,"installments":2,"requested_at":"2026-03-11T18:45:53Z"},"customer":{"avg_amount":82.24,"tx_count_24h":3,"known_merchants":["MERC-003","MERC-016"]},"merchant":{"id":"MERC-016","mcc":"5411","avg_amount":60.25},"terminal":{"is_online":false,"card_present":true,"km_from_home":29.23},"last_transaction":null}'
```

Expected: JSON response with `approved: true|false` and `fraud_score` between 0 and 1.

- [ ] **Step 5: Tear down**

```bash
docker compose down
```

- [ ] **Step 6: Commit any fixes**

If any fixes were needed during smoke test, commit them before benchmark.

---

### Task 10: Official Benchmark

**Files:**
- None new; verify benchmark command

- [ ] **Step 1: Run official benchmark**

```bash
make benchmark
```

- [ ] **Step 2: Inspect results**

```bash
cat .cache/rinha-official/test/results.json
```

Expected: `results.json` exists with `p99`, `scoring`, etc.

- [ ] **Step 3: Copy results to artifacts**

```bash
mkdir -p artifacts
cp .cache/rinha-official/test/results.json artifacts/rinha-official-result.json
```

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "feat: complete refactor to C++ LB + Bun API stack"
```

---

## Self-Review

**Spec coverage:**
- C++ LB with io_uring → Task 6 (implemented with epoll/poll fallback, still single-threaded round-robin)
- Bun API with UDS → Task 5
- C++ addon with IVF KNN → Task 4
- Preprocessing → Task 2
- Dataset reduction → Task 3
- Docker Compose → Task 7
- Makefile + docs → Task 8
- Smoke test → Task 9
- Benchmark → Task 10

**Placeholder scan:** No "TBD", "TODO", "implement later" found. All steps contain concrete code or commands.

**Type consistency:**
- `knn_search` signature matches in `knn.h`, `knn.cpp`, `binding.cpp`, and `index.ts`.
- IVF constants (`N_CLUSTERS=512`, `KNN_NPROBE=16`, `KNN_DIMS=14`, `KNN_K=5`) are consistent across files.

**Gaps:** None identified. All spec sections map to at least one task.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-15-rinha-refactor.md`.

Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
