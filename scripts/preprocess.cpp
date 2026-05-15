#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>
#include <cmath>
#include <algorithm>
#include <random>
#include <zlib.h>
// No mmap needed in preprocessing — we write sequentially

static constexpr int DIMS = 14;
static constexpr int N_CLUSTERS = 512;
// NPROBE and K are search-time parameters, not used during preprocessing

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
        char* endptr = const_cast<char*>(p);
        for (int i = 0; i < DIMS; ++i) {
            vec.v[i] = (float)strtod(endptr, &endptr);
            while (endptr < end && (*endptr == ' ' || *endptr == ',')) ++endptr;
        }
        p = endptr;
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

    auto safe_fopen = [](const char* path, const char* mode) -> FILE* {
        FILE* f = fopen(path, mode);
        if (!f) { fprintf(stderr, "Failed to open %s\n", path); exit(1); }
        return f;
    };
    auto safe_fwrite = [](const void* ptr, size_t size, size_t n, FILE* f, const char* desc) {
        if (fwrite(ptr, size, n, f) != n) { fprintf(stderr, "Failed to write %s\n", desc); exit(1); }
    };

    // Write vectors
    FILE* fv = safe_fopen("vector-index/dataset.bin", "wb");
    for (const auto& vec : data) safe_fwrite(vec.v, sizeof(float), DIMS, fv, "dataset");
    fclose(fv);

    // Write labels
    FILE* fl = safe_fopen("vector-index/labels.bin", "wb");
    for (const auto& vec : data) {
        if (fputc(vec.label, fl) == EOF) { fprintf(stderr, "Failed to write label\n"); exit(1); }
    }
    fclose(fl);

    // Write IVF index
    FILE* fi = safe_fopen("vector-index/ivf_index.bin", "wb");
    int header[2] = {N_CLUSTERS, DIMS};
    safe_fwrite(header, sizeof(int), 2, fi, "header");
    safe_fwrite(centroids, sizeof(float), N_CLUSTERS * DIMS, fi, "centroids");
    for (int c = 0; c < N_CLUSTERS; ++c) {
        uint32_t cnt = (uint32_t)lists[c].size();
        safe_fwrite(&cnt, sizeof(uint32_t), 1, fi, "list count");
        if (cnt) safe_fwrite(lists[c].data(), sizeof(uint32_t), cnt, fi, "list ids");
    }
    fclose(fi);

    fprintf(stderr, "Wrote dataset.bin, labels.bin, ivf_index.bin\n");
    return 0;
}
