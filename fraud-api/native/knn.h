#pragma once
#include "engine.h"
#include "ambiguous_head.h"
#include <cstdint>
#include <cstddef>
#include <vector>

static constexpr int KNN_DIMS = 14;
static constexpr int KNN_K = 5;
static constexpr int KNN_NPROBE = 8;
static constexpr int KNN_REFINE_NPROBE = 32;
static constexpr int KNN_MAX_CLUSTERS = 4096;

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
    KNNEngine() = default;
    ~KNNEngine();
    KNNEngine(const KNNEngine&) = delete;
    KNNEngine& operator=(const KNNEngine&) = delete;
    KNNEngine(KNNEngine&&) = delete;
    KNNEngine& operator=(KNNEngine&&) = delete;
    bool load(const char* dataset_path);
    bool load(const char* dataset_path, const char* labels_path, const char* index_path);
    float score(const float* vector14);
    void close();
    int search(const float* query, int k, uint32_t* out_indices, float* out_distances, uint8_t* out_labels) const;

private:
    bool load_manifest(const char* path);
    bool load_rules(const char* path);
    bool load_ambiguous_head(const char* path);
    static bool env_ambiguous_head_enabled();
    float apply_ambiguous_head(float ivf_score, const float* query, int found);
    float score_vector_fallback(const float* query);
    float score_knn_full(const float* query) const;
    float score_ivf_exact_local(const float* query, int n_probe_expand) const;
    int search_nprobe(const float* query, int k, int n_probe, uint32_t* out_indices, float* out_distances, uint8_t* out_labels) const;
    Dataset dataset_;
    IVFIndex ivf_;
    RulesModel rules_{};
    RuntimeCounters counters_{};
    AmbiguousHead ambiguous_head_{};
    size_t dataset_size_ = 0;
    size_t labels_size_ = 0;
    int k_runtime_ = KNN_K;
    bool ambiguous_head_enabled_ = true;
    bool ambiguous_head_env_enabled_ = true;
    bool ready_ = false;
};

extern "C" {
int fraud_init(const char* dataset_path);
float fraud_score(const float* vector14);
void fraud_close();
}
