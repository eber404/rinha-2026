#include "knn.h"
#include <cstring>

static KNNEngine g_engine;

extern "C" int knn_search(const float* query, int k, uint32_t* out_indices, float* out_distances, uint8_t* out_labels) {
    return g_engine.search(query, k, out_indices, out_distances, out_labels);
}

extern "C" int knn_init(const char* dataset_path, const char* labels_path, const char* index_path) {
    return g_engine.load(dataset_path, labels_path, index_path) ? 0 : -1;
}
