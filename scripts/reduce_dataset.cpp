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
