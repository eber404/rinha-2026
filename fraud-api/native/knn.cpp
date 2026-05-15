#include "knn.h"
#include <cstdio>
#include <cstring>
#include <cmath>
#include <algorithm>
#include <array>
#include <cassert>
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

KNNEngine::~KNNEngine() {
    if (dataset_.vectors && dataset_size_) {
        munmap(const_cast<void*>(static_cast<const void*>(dataset_.vectors)), dataset_size_);
    }
    if (dataset_.labels && labels_size_) {
        munmap(const_cast<void*>(static_cast<const void*>(dataset_.labels)), labels_size_);
    }
}

bool KNNEngine::load(const char* dataset_path, const char* labels_path, const char* index_path) {
    // Clean up any previously loaded data to avoid leaks on re-load
    this->~KNNEngine();
    new (this) KNNEngine();

    const void* dptr = nullptr;
    size_t dsize = 0;
    if (!mmap_file(dataset_path, &dptr, &dsize)) return false;
    dataset_.vectors = (const float*)dptr;
    dataset_.count = dsize / (sizeof(float) * KNN_DIMS);
    dataset_size_ = dsize;

    const void* lptr = nullptr;
    size_t lsize = 0;
    if (!mmap_file(labels_path, &lptr, &lsize)) return false;
    dataset_.labels = (const uint8_t*)lptr;
    labels_size_ = lsize;

    FILE* f = fopen(index_path, "rb");
    if (!f) return false;
    int header[2];
    if (fread(header, sizeof(int), 2, f) != 2) { fclose(f); return false; }
    ivf_.n_clusters = header[0];
    ivf_.dims = header[1];
    if (ivf_.dims != KNN_DIMS) { fclose(f); return false; }
    if (ivf_.n_clusters <= 0 || ivf_.n_clusters > 512) { fclose(f); return false; }
    ivf_.centroids.resize(ivf_.n_clusters * ivf_.dims);
    if (fread(ivf_.centroids.data(), sizeof(float), ivf_.centroids.size(), f) != ivf_.centroids.size()) { fclose(f); return false; }
    ivf_.lists.resize(ivf_.n_clusters);
    for (int c = 0; c < ivf_.n_clusters; ++c) {
        uint32_t cnt;
        if (fread(&cnt, sizeof(uint32_t), 1, f) != 1) { fclose(f); return false; }
        ivf_.lists[c].resize(cnt);
        if (cnt && fread(ivf_.lists[c].data(), sizeof(uint32_t), cnt, f) != cnt) { fclose(f); return false; }
    }
    fclose(f);
    return true;
}

int KNNEngine::search(const float* query, int k, uint32_t* out_indices, float* out_distances, uint8_t* out_labels) const {
    if (k <= 0) return 0;
    if (k > KNN_K) k = KNN_K;

    // Find closest clusters
    struct ClusterDist { int id; float dist; };
    std::array<ClusterDist, 512> cdists;
    for (int c = 0; c < ivf_.n_clusters; ++c) {
        cdists[c] = {c, l2_sq(query, &ivf_.centroids[c * ivf_.dims], ivf_.dims)};
    }
    int n_probe = std::min(KNN_NPROBE, ivf_.n_clusters);
    std::partial_sort(cdists.begin(), cdists.begin() + n_probe, cdists.begin() + ivf_.n_clusters,
                      [](const ClusterDist& a, const ClusterDist& b) { return a.dist < b.dist; });

    // Brute-force within NPROBE clusters, keep top-k
    struct Neighbor { uint32_t id; float dist; uint8_t label; };
    std::array<Neighbor, KNN_K> topk;
    size_t topk_size = 0;

    auto insert = [&](uint32_t id, float dist, uint8_t label) {
        if (topk_size < (size_t)k) {
            topk[topk_size] = {id, dist, label};
            ++topk_size;
            std::push_heap(topk.begin(), topk.begin() + topk_size, [](const Neighbor& a, const Neighbor& b) { return a.dist < b.dist; });
        } else if (dist < topk.front().dist) {
            std::pop_heap(topk.begin(), topk.begin() + topk_size, [](const Neighbor& a, const Neighbor& b) { return a.dist < b.dist; });
            topk[topk_size - 1] = {id, dist, label};
            std::push_heap(topk.begin(), topk.begin() + topk_size, [](const Neighbor& a, const Neighbor& b) { return a.dist < b.dist; });
        }
    };

    for (int i = 0; i < n_probe; ++i) {
        int c = cdists[i].id;
        for (uint32_t id : ivf_.lists[c]) {
            if (id >= dataset_.count) continue; // skip out-of-range IDs
            float dist = l2_sq(query, &dataset_.vectors[id * KNN_DIMS], KNN_DIMS);
            insert(id, dist, dataset_.labels[id]);
        }
    }

    std::sort(topk.begin(), topk.begin() + topk_size, [](const Neighbor& a, const Neighbor& b) { return a.dist < b.dist; });
    for (size_t i = 0; i < topk_size; ++i) {
        out_indices[i] = topk[i].id;
        out_distances[i] = topk[i].dist;
        out_labels[i] = topk[i].label;
    }
    return (int)topk_size;
}
