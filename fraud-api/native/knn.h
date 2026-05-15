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
    KNNEngine() = default;
    ~KNNEngine();
    bool load(const char* dataset_path, const char* labels_path, const char* index_path);
    int search(const float* query, int k, uint32_t* out_indices, float* out_distances, uint8_t* out_labels) const;

private:
    Dataset dataset_;
    IVFIndex ivf_;
    size_t dataset_size_ = 0;
    size_t labels_size_ = 0;
};
