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
