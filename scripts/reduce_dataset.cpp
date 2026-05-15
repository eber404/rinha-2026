#include <cstdio>
#include <vector>
#include <algorithm>
#include <random>
#include <cstring>
#include <cstdlib>

static constexpr int DIMS = 14;
static constexpr int N_CLUSTERS = 512;

struct Vector {
    float v[DIMS];
    uint8_t label;
};

static void die(const char* msg) {
    std::fprintf(stderr, "fatal: %s\n", msg);
    std::exit(1);
}

static FILE* safe_fopen(const char* path, const char* mode) {
    FILE* f = std::fopen(path, mode);
    if (!f) die(path);
    return f;
}

static void check_fread(size_t got, size_t expected, const char* what) {
    if (got != expected) die(what);
}

static void check_fwrite(size_t got, size_t expected, const char* what) {
    if (got != expected) die(what);
}

static long safe_ftell(FILE* f, const char* path) {
    long pos = std::ftell(f);
    if (pos < 0) die(path);
    return pos;
}

static void safe_fseek(FILE* f, long off, int whence, const char* path) {
    if (std::fseek(f, off, whence) != 0) die(path);
}

int main() {
    // Load full dataset
    FILE* fv = safe_fopen("vector-index/dataset.bin", "rb");
    safe_fseek(fv, 0, SEEK_END, "vector-index/dataset.bin fseek");
    long file_size = safe_ftell(fv, "vector-index/dataset.bin ftell");
    if (file_size % (sizeof(float) * DIMS) != 0)
        die("vector-index/dataset.bin: size not multiple of vector");
    size_t n = static_cast<size_t>(file_size) / (sizeof(float) * DIMS);
    safe_fseek(fv, 0, SEEK_SET, "vector-index/dataset.bin fseek");
    std::vector<Vector> data(n);
    for (size_t i = 0; i < n; ++i) {
        check_fread(std::fread(data[i].v, sizeof(float), DIMS, fv), DIMS,
                    "vector-index/dataset.bin fread");
    }
    std::fclose(fv);

    FILE* fl = safe_fopen("vector-index/labels.bin", "rb");
    for (size_t i = 0; i < n; ++i) {
        int ch = std::fgetc(fl);
        if (ch == EOF) die("vector-index/labels.bin: unexpected EOF");
        data[i].label = static_cast<uint8_t>(ch);
    }
    std::fclose(fl);

    // Load IVF index to get cluster assignments
    FILE* fi = safe_fopen("vector-index/ivf_index.bin", "rb");
    int header[2];
    check_fread(std::fread(header, sizeof(int), 2, fi), 2,
                "vector-index/ivf_index.bin header fread");
    std::vector<float> centroids(static_cast<size_t>(header[0]) * header[1]);
    check_fread(std::fread(centroids.data(), sizeof(float), centroids.size(), fi),
                centroids.size(), "vector-index/ivf_index.bin centroids fread");
    std::vector<std::vector<uint32_t>> lists(header[0]);
    for (int c = 0; c < header[0]; ++c) {
        uint32_t cnt;
        check_fread(std::fread(&cnt, sizeof(uint32_t), 1, fi), 1,
                    "vector-index/ivf_index.bin count fread");
        lists[c].resize(cnt);
        if (cnt) {
            check_fread(std::fread(lists[c].data(), sizeof(uint32_t), cnt, fi), cnt,
                        "vector-index/ivf_index.bin list fread");
        }
    }
    std::fclose(fi);

    // Stratified reduction: keep 10% of each cluster, minimum 5 per cluster
    std::mt19937 rng(42);
    std::vector<Vector> reduced;
    for (int c = 0; c < N_CLUSTERS; ++c) {
        size_t keep = std::max((size_t)5, (size_t)(lists[c].size() * 0.10));
        if (keep > lists[c].size()) keep = lists[c].size();
        std::shuffle(lists[c].begin(), lists[c].end(), rng);
        for (size_t i = 0; i < keep; ++i) {
            reduced.push_back(data[lists[c][i]]);
        }
    }

    // Write reduced dataset
    FILE* rfv = safe_fopen("vector-index/dataset_reduced.bin", "wb");
    for (const auto& vec : reduced) {
        check_fwrite(std::fwrite(vec.v, sizeof(float), DIMS, rfv), DIMS,
                     "vector-index/dataset_reduced.bin fwrite");
    }
    std::fclose(rfv);

    FILE* rfl = safe_fopen("vector-index/labels_reduced.bin", "wb");
    for (const auto& vec : reduced) {
        if (std::fputc(vec.label, rfl) == EOF)
            die("vector-index/labels_reduced.bin: fputc failed");
    }
    std::fclose(rfl);

    // Build reduced IVF index (re-cluster reduced set into 512 clusters)
    std::vector<float> rcents(N_CLUSTERS * DIMS);
    for (int c = 0; c < N_CLUSTERS; ++c) {
        std::memcpy(&rcents[c * DIMS], reduced[rng() % reduced.size()].v, sizeof(float) * DIMS);
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
                std::memcpy(&rcents[c * DIMS], reduced[rng() % reduced.size()].v, sizeof(float) * DIMS);
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

    FILE* rfi = safe_fopen("vector-index/ivf_index_reduced.bin", "wb");
    int h[2] = {N_CLUSTERS, DIMS};
    check_fwrite(std::fwrite(h, sizeof(int), 2, rfi), 2,
                 "vector-index/ivf_index_reduced.bin header fwrite");
    check_fwrite(std::fwrite(rcents.data(), sizeof(float), N_CLUSTERS * DIMS, rfi),
                 static_cast<size_t>(N_CLUSTERS) * DIMS,
                 "vector-index/ivf_index_reduced.bin centroids fwrite");
    for (int c = 0; c < N_CLUSTERS; ++c) {
        uint32_t cnt = (uint32_t)rlists[c].size();
        check_fwrite(std::fwrite(&cnt, sizeof(uint32_t), 1, rfi), 1,
                     "vector-index/ivf_index_reduced.bin count fwrite");
        if (cnt) {
            check_fwrite(std::fwrite(rlists[c].data(), sizeof(uint32_t), cnt, rfi), cnt,
                         "vector-index/ivf_index_reduced.bin list fwrite");
        }
    }
    std::fclose(rfi);

    std::fprintf(stderr, "Reduced dataset: %zu vectors (%.1f%%)\n", reduced.size(), 100.0 * reduced.size() / n);
    return 0;
}
