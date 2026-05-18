#include "knn.h"
#include <cstdio>
#include <cstring>
#include <cmath>
#include <algorithm>
#include <array>
#include <cassert>
#include <string>
#include <cstdlib>
#include <cerrno>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static bool parse_env_bool(const char* value, bool default_value) {
    if (!value || value[0] == '\0') return default_value;
    if (std::strcmp(value, "0") == 0 || std::strcmp(value, "off") == 0 || std::strcmp(value, "false") == 0) return false;
    if (std::strcmp(value, "1") == 0 || std::strcmp(value, "on") == 0 || std::strcmp(value, "true") == 0) return true;
    return default_value;
}

static inline float l2_sq(const float* a, const float* b) {
    float s = 0.0f;
    for (int i = 0; i < KNN_DIMS; ++i) {
        float d = a[i] - b[i];
        s += d * d;
    }
    return s;
}

static inline uint32_t clamp_bin(float value, float step, int max_bin) {
    if (!std::isfinite(value) || value < 0.0f) return 0;
    int bin = static_cast<int>(value / step);
    if (bin < 0) bin = 0;
    if (bin > max_bin) bin = max_bin;
    return static_cast<uint32_t>(bin);
}

static constexpr int BUCKET_REFINE_NEIGHBOR_RADIUS = 3;

static DirectDecision decide_conservative(const float* v, const RulesModel& r) {
    if (!v) return DirectDecision::AMBIGUOUS;
    const uint32_t leaf_count = std::min<uint32_t>(r.leaf_count, FRAUD_MAX_RULE_LEAVES);
    for (uint32_t i = 0; i < leaf_count; ++i) {
        const auto& leaf = r.leaves[i];
        if (leaf.feature_count == 0 || leaf.feature_count > FRAUD_MAX_LEAF_FEATURES) continue;
        bool match = true;
        for (uint8_t j = 0; j < leaf.feature_count; ++j) {
            const uint8_t feature = leaf.features[j];
            if (feature >= KNN_DIMS) { match = false; break; }
            const float value = v[feature];
            if (value < leaf.min_values[j] || value > leaf.max_values[j]) {
                match = false;
                break;
            }
        }
        if (!match) continue;
        if (leaf.decision == static_cast<uint8_t>(DirectDecision::CLEAR_LEGIT)) return DirectDecision::CLEAR_LEGIT;
        if (leaf.decision == static_cast<uint8_t>(DirectDecision::CLEAR_FRAUD)) return DirectDecision::CLEAR_FRAUD;
    }

    const float amount_vs_avg = v[2];
    const float km_home = v[7];
    const float mcc_risk = v[12];
    const float unknown_merchant = v[11];

    if (amount_vs_avg <= r.max_amount_vs_avg_legit &&
        km_home <= r.max_km_home_legit &&
        unknown_merchant < 0.5f) {
        return DirectDecision::CLEAR_LEGIT;
    }
    if (amount_vs_avg >= r.min_amount_vs_avg_fraud &&
        km_home >= r.min_km_home_fraud &&
        mcc_risk >= r.min_mcc_risk_fraud) {
        return DirectDecision::CLEAR_FRAUD;
    }
    return DirectDecision::AMBIGUOUS;
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
    close();
}

void KNNEngine::close() {
    if (dataset_.vectors && dataset_size_) {
        munmap(const_cast<void*>(static_cast<const void*>(dataset_.vectors)), dataset_size_);
    }
    if (dataset_.labels && labels_size_) {
        munmap(const_cast<void*>(static_cast<const void*>(dataset_.labels)), labels_size_);
    }
    dataset_ = Dataset{};
    ivf_ = IVFIndex{};
    bucket_keys_.clear();
    bucket_lists_.clear();
    rules_ = RulesModel{};
    counters_ = RuntimeCounters{};
    ambiguous_head_.close();
    dataset_size_ = 0;
    labels_size_ = 0;
    k_runtime_ = KNN_K;
    ambiguous_head_enabled_ = true;
    ambiguous_head_env_enabled_ = true;
    ready_ = false;
}

uint32_t KNNEngine::bucket_key(const float* v) {
    if (!v) return 0;
    const uint32_t has_last_tx = (v[5] >= 0.0f) ? 1u : 0u;
    const uint32_t is_online = (v[9] > 0.5f) ? 1u : 0u;
    const uint32_t card_present = (v[10] > 0.5f) ? 1u : 0u;
    const uint32_t unknown_merchant = (v[11] > 0.5f) ? 1u : 0u;
    const uint32_t high_mcc = (v[12] >= 0.6f) ? 1u : 0u;

    const uint32_t amount_bin = clamp_bin(v[2], 0.125f, 7);
    const uint32_t tx_count_bin = clamp_bin(v[8], 0.125f, 7);
    const uint32_t km_bin = clamp_bin(v[7], 0.125f, 7);
    const uint32_t hour_bin = clamp_bin(v[3], 0.25f, 3);

    uint32_t key = 0;
    key |= has_last_tx;
    key |= (is_online << 1);
    key |= (card_present << 2);
    key |= (unknown_merchant << 3);
    key |= (high_mcc << 4);
    key |= (amount_bin << 5);
    key |= (tx_count_bin << 8);
    key |= (km_bin << 11);
    key |= (hour_bin << 14);
    return key;
}

int KNNEngine::bucket_distance(uint32_t a, uint32_t b) {
    const uint32_t x = a ^ b;
    return __builtin_popcount(x);
}

bool KNNEngine::load_manifest(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) return false;
    uint32_t raw[6] = {0, 0, 0, 0, 0, 1};
    const size_t read = fread(raw, sizeof(uint32_t), 6, f);
    fclose(f);
    if (read < 5) return false;
    ManifestHeader mh{};
    mh.magic = raw[0];
    mh.version = raw[1];
    mh.dims = raw[2];
    mh.k_default = raw[3];
    mh.bucket_enabled = raw[4];
    mh.ambiguous_head_enabled = (read >= 6) ? raw[5] : 1;
    if (mh.magic != FRAUD_MAGIC || mh.version != FRAUD_VERSION || mh.dims != FRAUD_DIMS) return false;
    if (mh.k_default == 0 || mh.k_default > KNN_K) return false;
    k_runtime_ = static_cast<int>(mh.k_default);
    ambiguous_head_enabled_ = mh.ambiguous_head_enabled != 0;
    return true;
}

bool KNNEngine::load_rules(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) return false;
    RulesModel rules{};
    const bool ok = fread(&rules, sizeof(rules), 1, f) == 1;
    fclose(f);
    if (!ok) return false;
    if (rules.leaf_count > FRAUD_MAX_RULE_LEAVES) return false;
    if (!std::isfinite(rules.min_conf_legit) || !std::isfinite(rules.min_conf_fraud) ||
        !std::isfinite(rules.min_mcc_risk_fraud) || !std::isfinite(rules.max_amount_vs_avg_legit) ||
        !std::isfinite(rules.min_amount_vs_avg_fraud) || !std::isfinite(rules.max_km_home_legit) ||
        !std::isfinite(rules.min_km_home_fraud)) {
        return false;
    }
    for (uint32_t i = 0; i < rules.leaf_count; ++i) {
        const auto& leaf = rules.leaves[i];
        if (leaf.feature_count == 0 || leaf.feature_count > FRAUD_MAX_LEAF_FEATURES) return false;
        if (leaf.decision != static_cast<uint8_t>(DirectDecision::CLEAR_LEGIT) &&
            leaf.decision != static_cast<uint8_t>(DirectDecision::CLEAR_FRAUD)) return false;
        for (uint8_t j = 0; j < leaf.feature_count; ++j) {
            if (leaf.features[j] >= KNN_DIMS) return false;
            const float min_v = leaf.min_values[j];
            const float max_v = leaf.max_values[j];
            if (!std::isfinite(min_v) || !std::isfinite(max_v)) return false;
            if (min_v > max_v) return false;
        }
    }
    rules_ = rules;
    return true;
}

bool KNNEngine::env_ambiguous_head_enabled() {
    return parse_env_bool(std::getenv("FRAUD_AMBIGUOUS_HEAD"), false);
}

bool KNNEngine::load_ambiguous_head(const char* path) {
    if (!ambiguous_head_enabled_ || !ambiguous_head_env_enabled_) return false;
    return ambiguous_head_.load(path);
}

bool KNNEngine::load(const char* dataset_path) {
    if (!dataset_path || dataset_path[0] == '\0') return false;

    struct stat st;
    if (stat(dataset_path, &st) != 0) return false;

    if (S_ISDIR(st.st_mode)) {
        std::string base(dataset_path);
        if (!base.empty() && base.back() != '/') base.push_back('/');
        const std::string manifest_file = base + "manifest.bin";
        const std::string rules_file = base + "rules_model.bin";
        std::string dataset_file = base + "dataset_full.bin";
        std::string labels_file = base + "labels_full.bin";
        if (access(dataset_file.c_str(), R_OK) != 0) dataset_file = base + "dataset.bin";
        if (access(labels_file.c_str(), R_OK) != 0) labels_file = base + "labels.bin";
        const std::string index_file = base + "ivf_index.bin";
        const std::string head_file = base + "ambiguous_head.bin";
        const bool ok = load(dataset_file.c_str(), labels_file.c_str(), index_file.c_str());
        if (!ok || !load_manifest(manifest_file.c_str()) || !load_rules(rules_file.c_str())) {
            close();
            return false;
        }
        ambiguous_head_env_enabled_ = env_ambiguous_head_enabled();
        load_ambiguous_head(head_file.c_str());
        ready_ = true;
        return true;
    }

    return load(dataset_path, "labels.bin", "ivf_index.bin");
}

bool KNNEngine::load(const char* dataset_path, const char* labels_path, const char* index_path) {
    close();

    const void* dptr = nullptr;
    size_t dsize = 0;
    if (!mmap_file(dataset_path, &dptr, &dsize)) return false;
    if (dsize == 0 || dsize % (sizeof(float) * KNN_DIMS) != 0) { close(); return false; }
    dataset_.vectors = (const float*)dptr;
    dataset_.count = dsize / (sizeof(float) * KNN_DIMS);
    dataset_size_ = dsize;

    const void* lptr = nullptr;
    size_t lsize = 0;
    if (!mmap_file(labels_path, &lptr, &lsize)) { close(); return false; }
    if (lsize < dataset_.count) { close(); return false; }
    dataset_.labels = (const uint8_t*)lptr;
    labels_size_ = lsize;

    bucket_keys_.resize(dataset_.count);
    bucket_lists_.clear();
    bucket_lists_.reserve(1024);
    for (size_t i = 0; i < dataset_.count; ++i) {
        const uint32_t key = bucket_key(&dataset_.vectors[i * KNN_DIMS]);
        bucket_keys_[i] = key;
        bucket_lists_[key].push_back(static_cast<uint32_t>(i));
    }

    FILE* f = fopen(index_path, "rb");
    if (!f) { close(); return false; }
    int header[2];
    if (fread(header, sizeof(int), 2, f) != 2) { fclose(f); close(); return false; }
    ivf_.n_clusters = header[0];
    ivf_.dims = header[1];
    if (ivf_.dims != KNN_DIMS) { fclose(f); close(); return false; }
    if (ivf_.n_clusters <= 0 || ivf_.n_clusters > KNN_MAX_CLUSTERS) { fclose(f); close(); return false; }
    ivf_.centroids.resize(ivf_.n_clusters * ivf_.dims);
    if (fread(ivf_.centroids.data(), sizeof(float), ivf_.centroids.size(), f) != ivf_.centroids.size()) { fclose(f); close(); return false; }
    ivf_.lists.resize(ivf_.n_clusters);
    for (int c = 0; c < ivf_.n_clusters; ++c) {
        uint32_t cnt;
        if (fread(&cnt, sizeof(uint32_t), 1, f) != 1) { fclose(f); close(); return false; }
        ivf_.lists[c].resize(cnt);
        if (cnt && fread(ivf_.lists[c].data(), sizeof(uint32_t), cnt, f) != cnt) { fclose(f); close(); return false; }
    }
    fclose(f);
    ready_ = true;
    return true;
}

float KNNEngine::score(const float* vector14) {
    if (!ready_) return 0.5f;
    const DirectDecision decision = decide_conservative(vector14, rules_);
    if (decision == DirectDecision::CLEAR_LEGIT) {
        counters_.clear_legit++;
        const uint64_t total = counters_.clear_legit + counters_.clear_fraud + counters_.ambiguous;
        if (total && total % 10000 == 0) {
            std::fprintf(stderr, "fraud_stats total=%lu clear_legit=%lu clear_fraud=%lu ambiguous=%lu fallback_full=%lu fallback_bucket=%lu fallback_ivf=%lu refinement_exact=%lu refinement_changed=%lu sample_exact=%lu sample_disagree=%lu ambiguous_head_used=%lu ambiguous_head_bypassed=%lu bucket_refine_triggered=%lu bucket_refine_used=%lu bucket_refine_same_only=%lu bucket_refine_neighbor=%lu bucket_refine_no_candidates=%lu\n",
                         total, counters_.clear_legit, counters_.clear_fraud, counters_.ambiguous, counters_.fallback_full, counters_.fallback_bucket,
                         counters_.fallback_ivf, counters_.refinement_exact, counters_.refinement_changed, counters_.sample_exact, counters_.sample_disagree,
                         counters_.ambiguous_head_used, counters_.ambiguous_head_bypassed,
                         counters_.bucket_refine_triggered, counters_.bucket_refine_used, counters_.bucket_refine_same_only,
                         counters_.bucket_refine_neighbor, counters_.bucket_refine_no_candidates);
        }
        return 0.0f;
    }
    if (decision == DirectDecision::CLEAR_FRAUD) {
        counters_.clear_fraud++;
        const uint64_t total = counters_.clear_legit + counters_.clear_fraud + counters_.ambiguous;
        if (total && total % 10000 == 0) {
            std::fprintf(stderr, "fraud_stats total=%lu clear_legit=%lu clear_fraud=%lu ambiguous=%lu fallback_full=%lu fallback_bucket=%lu fallback_ivf=%lu refinement_exact=%lu refinement_changed=%lu sample_exact=%lu sample_disagree=%lu ambiguous_head_used=%lu ambiguous_head_bypassed=%lu bucket_refine_triggered=%lu bucket_refine_used=%lu bucket_refine_same_only=%lu bucket_refine_neighbor=%lu bucket_refine_no_candidates=%lu\n",
                         total, counters_.clear_legit, counters_.clear_fraud, counters_.ambiguous, counters_.fallback_full, counters_.fallback_bucket,
                         counters_.fallback_ivf, counters_.refinement_exact, counters_.refinement_changed, counters_.sample_exact, counters_.sample_disagree,
                         counters_.ambiguous_head_used, counters_.ambiguous_head_bypassed,
                         counters_.bucket_refine_triggered, counters_.bucket_refine_used, counters_.bucket_refine_same_only,
                         counters_.bucket_refine_neighbor, counters_.bucket_refine_no_candidates);
        }
        return 1.0f;
    }
    counters_.ambiguous++;
    counters_.fallback_full++;
    const uint64_t total = counters_.clear_legit + counters_.clear_fraud + counters_.ambiguous;
    if (total && total % 10000 == 0) {
        std::fprintf(stderr, "fraud_stats total=%lu clear_legit=%lu clear_fraud=%lu ambiguous=%lu fallback_full=%lu fallback_bucket=%lu fallback_ivf=%lu refinement_exact=%lu refinement_changed=%lu sample_exact=%lu sample_disagree=%lu ambiguous_head_used=%lu ambiguous_head_bypassed=%lu bucket_refine_triggered=%lu bucket_refine_used=%lu bucket_refine_same_only=%lu bucket_refine_neighbor=%lu bucket_refine_no_candidates=%lu\n",
                     total, counters_.clear_legit, counters_.clear_fraud, counters_.ambiguous, counters_.fallback_full, counters_.fallback_bucket,
                     counters_.fallback_ivf, counters_.refinement_exact, counters_.refinement_changed, counters_.sample_exact, counters_.sample_disagree,
                     counters_.ambiguous_head_used, counters_.ambiguous_head_bypassed,
                     counters_.bucket_refine_triggered, counters_.bucket_refine_used, counters_.bucket_refine_same_only,
                     counters_.bucket_refine_neighbor, counters_.bucket_refine_no_candidates);
    }
    return score_vector_fallback(vector14);
}

float KNNEngine::score_ivf_exact_local(const float* query, int n_probe_expand) const {
    if (!query || !dataset_.vectors || !dataset_.labels || ivf_.n_clusters <= 0) return 0.5f;
    if (n_probe_expand <= 0) n_probe_expand = KNN_NPROBE;

    // Select top clusters
    struct ClusterDist { int id; float dist; };
    std::array<ClusterDist, KNN_MAX_CLUSTERS> cdists;
    for (int c = 0; c < ivf_.n_clusters; ++c) {
        cdists[c] = {c, l2_sq(query, &ivf_.centroids[c * ivf_.dims])};
    }
    const int n_probe = std::min(n_probe_expand, ivf_.n_clusters);
    std::partial_sort(cdists.begin(), cdists.begin() + n_probe, cdists.begin() + ivf_.n_clusters,
                      [](const ClusterDist& a, const ClusterDist& b) { return a.dist < b.dist; });

    // Collect all candidate IDs from selected clusters
    static constexpr int MAX_LOCAL_CANDIDATES = 65536;
    uint32_t candidates[MAX_LOCAL_CANDIDATES];
    int candidate_count = 0;
    for (int i = 0; i < n_probe; ++i) {
        int c = cdists[i].id;
        for (uint32_t id : ivf_.lists[c]) {
            if (id >= dataset_.count) continue;
            if (candidate_count < MAX_LOCAL_CANDIDATES) {
                candidates[candidate_count++] = id;
            }
        }
    }
    if (candidate_count == 0) return 0.5f;

    const int k = std::min(k_runtime_, KNN_K);
    float best_dists[5] = {1e30f, 1e30f, 1e30f, 1e30f, 1e30f};
    uint8_t best_labels[5] = {0, 0, 0, 0, 0};
    int found = 0;

    for (int i = 0; i < candidate_count; ++i) {
        uint32_t id = candidates[i];
        float dist = l2_sq(query, &dataset_.vectors[id * KNN_DIMS]);
        if (found < k) {
            best_dists[found] = dist;
            best_labels[found] = dataset_.labels[id];
            ++found;
            for (int j = found - 1; j > 0 && best_dists[j] < best_dists[j-1]; --j) {
                float td = best_dists[j]; best_dists[j] = best_dists[j-1]; best_dists[j-1] = td;
                uint8_t tl = best_labels[j]; best_labels[j] = best_labels[j-1]; best_labels[j-1] = tl;
            }
        } else if (dist < best_dists[k-1]) {
            best_dists[k-1] = dist;
            best_labels[k-1] = dataset_.labels[id];
            for (int j = k-1; j > 0 && best_dists[j] < best_dists[j-1]; --j) {
                float td = best_dists[j]; best_dists[j] = best_dists[j-1]; best_dists[j-1] = td;
                uint8_t tl = best_labels[j]; best_labels[j] = best_labels[j-1]; best_labels[j-1] = tl;
            }
        }
    }

    if (found == 0) return 0.5f;
    int frauds = 0;
    for (int i = 0; i < found; ++i) frauds += best_labels[i] ? 1 : 0;
    return static_cast<float>(frauds) / static_cast<float>(found);
}

float KNNEngine::score_vector_fallback(const float* query) {
    if (!query) return 0.5f;
    if (dataset_.count <= 10000) return score_knn_full(query);
    uint32_t indices[KNN_K];
    float distances[KNN_K];
    uint8_t labels[KNN_K];
    const int found = search(query, k_runtime_, indices, distances, labels);
    if (found < k_runtime_) {
        counters_.refinement_exact++;
        return score_knn_full(query);
    }

    int frauds = 0;
    for (int i = 0; i < found; ++i) frauds += labels[i] ? 1 : 0;
    counters_.fallback_ivf++;
    const float ivf_score = static_cast<float>(frauds) / static_cast<float>(found);
    if ((counters_.fallback_ivf & 32767ULL) == 0) {
        counters_.sample_exact++;
        const float exact_score = score_knn_full(query);
        if ((ivf_score < 0.6f) != (exact_score < 0.6f)) counters_.sample_disagree++;
    }
    counters_.bucket_refine_triggered++;
    int local_found = 0;
    float refined = score_knn_bucket(query, 0, &local_found);
    if (local_found >= k_runtime_) {
        counters_.bucket_refine_used++;
        counters_.bucket_refine_same_only++;
        return apply_ambiguous_head(refined, query, local_found);
    }

    refined = score_knn_bucket(query, BUCKET_REFINE_NEIGHBOR_RADIUS, &local_found);
    if (local_found >= k_runtime_) {
        counters_.bucket_refine_used++;
        counters_.bucket_refine_neighbor++;
        return apply_ambiguous_head(refined, query, local_found);
    }
    counters_.bucket_refine_no_candidates++;

    float base_score = ivf_score;
    if (ivf_score == 0.4f) base_score = 0.6f;
    if (ivf_score == 0.6f) base_score = 0.4f;
    return apply_ambiguous_head(base_score, query, found);
}

float KNNEngine::apply_ambiguous_head(float ivf_score, const float* query, int found) {
    if (!ambiguous_head_enabled_ || !ambiguous_head_env_enabled_ || !ambiguous_head_.loaded()) {
        counters_.ambiguous_head_bypassed++;
        return ivf_score;
    }
    counters_.ambiguous_head_used++;
    float features[AMBIGUOUS_HEAD_MAX_FEATURES] = {0.0f, 0.0f, 0.0f, 0.0f};
    features[0] = ivf_score;
    features[1] = std::fabs(ivf_score - 0.5f);
    features[2] = query ? query[12] : 0.0f;
    features[3] = static_cast<float>(found) / static_cast<float>(KNN_K);
    return ambiguous_head_.infer(features, AMBIGUOUS_HEAD_MAX_FEATURES);
}

float KNNEngine::score_knn_full(const float* query) const {
    if (!query || !dataset_.vectors || !dataset_.labels || dataset_.count == 0) return 0.5f;
    const int k = std::min(k_runtime_, KNN_K);
    float distances[KNN_K];
    uint8_t labels[KNN_K];
    int found = 0;
    for (int i = 0; i < k; ++i) {
        distances[i] = 1e30f;
        labels[i] = 0;
    }

    for (size_t id = 0; id < dataset_.count; ++id) {
        const float dist = l2_sq(query, &dataset_.vectors[id * KNN_DIMS]);
        if (found < k) {
            distances[found] = dist;
            labels[found] = dataset_.labels[id];
            ++found;
        } else if (dist >= distances[k - 1]) {
            continue;
        } else {
            distances[k - 1] = dist;
            labels[k - 1] = dataset_.labels[id];
        }
        for (int j = found < k ? found - 1 : k - 1; j > 0 && distances[j] < distances[j - 1]; --j) {
            std::swap(distances[j], distances[j - 1]);
            std::swap(labels[j], labels[j - 1]);
        }
    }
    if (found == 0) return 0.5f;

    int frauds = 0;
    for (int i = 0; i < found; ++i) {
        frauds += labels[i] ? 1 : 0;
    }
    return static_cast<float>(frauds) / static_cast<float>(found);
}

float KNNEngine::score_knn_bucket(const float* query, int bucket_radius, int* out_found) const {
    if (!query || !dataset_.vectors || !dataset_.labels || dataset_.count == 0) {
        if (out_found) *out_found = 0;
        return 0.5f;
    }
    if (bucket_radius < 0) bucket_radius = 0;

    const uint32_t qkey = bucket_key(query);
    const int k = std::min(k_runtime_, KNN_K);
    float distances[KNN_K];
    uint8_t labels[KNN_K];
    int found = 0;
    for (int i = 0; i < k; ++i) {
        distances[i] = 1e30f;
        labels[i] = 0;
    }

    auto consume_id = [&](uint32_t id) {
        const float dist = l2_sq(query, &dataset_.vectors[id * KNN_DIMS]);
        if (found < k) {
            distances[found] = dist;
            labels[found] = dataset_.labels[id];
            ++found;
        } else if (dist < distances[k - 1]) {
            distances[k - 1] = dist;
            labels[k - 1] = dataset_.labels[id];
        } else {
            return;
        }
        for (int j = found < k ? found - 1 : k - 1; j > 0 && distances[j] < distances[j - 1]; --j) {
            std::swap(distances[j], distances[j - 1]);
            std::swap(labels[j], labels[j - 1]);
        }
    };

    if (bucket_radius == 0) {
        const auto it = bucket_lists_.find(qkey);
        if (it != bucket_lists_.end()) {
            for (uint32_t id : it->second) consume_id(id);
        }
    } else {
        for (const auto& entry : bucket_lists_) {
            if (bucket_distance(qkey, entry.first) > bucket_radius) continue;
            for (uint32_t id : entry.second) consume_id(id);
        }
    }

    if (out_found) *out_found = found;
    if (found == 0) return 0.5f;

    int frauds = 0;
    for (int i = 0; i < found; ++i) frauds += labels[i] ? 1 : 0;
    return static_cast<float>(frauds) / static_cast<float>(found);
}

int KNNEngine::search(const float* query, int k, uint32_t* out_indices, float* out_distances, uint8_t* out_labels) const {
    return search_nprobe(query, k, KNN_NPROBE, out_indices, out_distances, out_labels);
}

int KNNEngine::search_nprobe(const float* query, int k, int n_probe_requested, uint32_t* out_indices, float* out_distances, uint8_t* out_labels) const {
    if (!query || !dataset_.vectors || !dataset_.labels || ivf_.n_clusters <= 0 || ivf_.centroids.empty()) return 0;
    if (k <= 0) return 0;
    if (k > KNN_K) k = KNN_K;

    // Find closest clusters
    struct ClusterDist { int id; float dist; };
    std::array<ClusterDist, KNN_MAX_CLUSTERS> cdists;
    for (int c = 0; c < ivf_.n_clusters; ++c) {
        cdists[c] = {c, l2_sq(query, &ivf_.centroids[c * ivf_.dims])};
    }
    int n_probe = std::min(n_probe_requested, ivf_.n_clusters);
    std::partial_sort(cdists.begin(), cdists.begin() + n_probe, cdists.begin() + ivf_.n_clusters,
                      [](const ClusterDist& a, const ClusterDist& b) { return a.dist < b.dist; });

    // Brute-force within NPROBE clusters, keep top-k using simple arrays
    float best_dists[5] = {1e30f, 1e30f, 1e30f, 1e30f, 1e30f};
    uint32_t best_ids[5] = {0, 0, 0, 0, 0};
    uint8_t best_labels[5] = {0, 0, 0, 0, 0};
    int found = 0;

    for (int i = 0; i < n_probe; ++i) {
        int c = cdists[i].id;
        for (uint32_t id : ivf_.lists[c]) {
            if (id >= dataset_.count) continue;
            float dist = l2_sq(query, &dataset_.vectors[id * KNN_DIMS]);
            if (found < k) {
                best_dists[found] = dist;
                best_ids[found] = id;
                best_labels[found] = dataset_.labels[id];
                ++found;
                // Bubble up
                for (int j = found - 1; j > 0 && best_dists[j] < best_dists[j-1]; --j) {
                    float td = best_dists[j]; best_dists[j] = best_dists[j-1]; best_dists[j-1] = td;
                    uint32_t ti = best_ids[j]; best_ids[j] = best_ids[j-1]; best_ids[j-1] = ti;
                    uint8_t tl = best_labels[j]; best_labels[j] = best_labels[j-1]; best_labels[j-1] = tl;
                }
            } else if (dist < best_dists[k-1]) {
                best_dists[k-1] = dist;
                best_ids[k-1] = id;
                best_labels[k-1] = dataset_.labels[id];
                for (int j = k-1; j > 0 && best_dists[j] < best_dists[j-1]; --j) {
                    float td = best_dists[j]; best_dists[j] = best_dists[j-1]; best_dists[j-1] = td;
                    uint32_t ti = best_ids[j]; best_ids[j] = best_ids[j-1]; best_ids[j-1] = ti;
                    uint8_t tl = best_labels[j]; best_labels[j] = best_labels[j-1]; best_labels[j-1] = tl;
                }
            }
        }
    }

    for (int i = 0; i < found; ++i) {
        out_indices[i] = best_ids[i];
        out_distances[i] = best_dists[i];
        out_labels[i] = best_labels[i];
    }
    return found;
}
