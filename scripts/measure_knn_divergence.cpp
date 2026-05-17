#include <algorithm>
#include <array>
#include <cassert>
#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <sys/stat.h>

static constexpr int DIMS = 14;
static constexpr int K = 5;
static constexpr int NPROBE = 8;
static constexpr int MAX_CLUSTERS = 4096;
static constexpr uint32_t FRAUD_MAGIC = 0x46445231;
static constexpr uint32_t FRAUD_VERSION = 1;
static constexpr int MAX_RULE_LEAVES = 256;
static constexpr int MAX_LEAF_FEATURES = 4;

enum class DirectDecision : uint8_t {
    CLEAR_LEGIT = 0,
    CLEAR_FRAUD = 1,
    AMBIGUOUS = 2,
};

struct RulesModel {
    float min_conf_legit;
    float min_conf_fraud;
    float min_mcc_risk_fraud;
    float max_amount_vs_avg_legit;
    float min_amount_vs_avg_fraud;
    float max_km_home_legit;
    float min_km_home_fraud;
    uint32_t leaf_count;
    struct RuleLeaf {
        uint8_t decision;
        uint8_t feature_count;
        uint8_t features[MAX_LEAF_FEATURES];
        uint8_t reserved[2];
        float min_values[MAX_LEAF_FEATURES];
        float max_values[MAX_LEAF_FEATURES];
        uint32_t support;
    } leaves[MAX_RULE_LEAVES];
};

struct ManifestHeader {
    uint32_t magic;
    uint32_t version;
    uint32_t dims;
    uint32_t k_default;
    uint32_t bucket_enabled;
    uint32_t ambiguous_head_enabled;
};

struct Dataset {
    std::vector<float> vectors;
    std::vector<uint8_t> labels;
    size_t count() const { return labels.size(); }
};

struct IVFIndex {
    int n_clusters = 0;
    int dims = 0;
    std::vector<float> centroids;
    std::vector<std::vector<uint32_t>> lists;
};

struct Metrics {
    uint64_t samples = 0;
    uint64_t direct_clear = 0;
    uint64_t direct_clear_exact_disagree = 0;
    uint64_t ambiguous = 0;
    uint64_t ivf_exact_score_disagree = 0;
    uint64_t ivf_exact_decision_disagree = 0;
    uint64_t runtime_exact_decision_disagree = 0;
    uint64_t boundary_04 = 0;
    uint64_t boundary_06 = 0;
};

static inline float l2_sq(const float* a, const float* b) {
    float s = 0.0f;
    for (int i = 0; i < DIMS; ++i) {
        const float d = a[i] - b[i];
        s += d * d;
    }
    return s;
}

static bool read_file_bytes(const std::string& path, std::vector<uint8_t>& out) {
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return false;
    struct stat st{};
    if (stat(path.c_str(), &st) != 0 || st.st_size < 0) {
        std::fclose(f);
        return false;
    }
    out.resize(static_cast<size_t>(st.st_size));
    if (!out.empty() && std::fread(out.data(), 1, out.size(), f) != out.size()) {
        std::fclose(f);
        return false;
    }
    std::fclose(f);
    return true;
}

static bool load_dataset(const std::string& data_dir, Dataset& dataset) {
    std::vector<uint8_t> vector_bytes;
    if (!read_file_bytes(data_dir + "/dataset_full.bin", vector_bytes)) return false;
    if (vector_bytes.empty() || vector_bytes.size() % (sizeof(float) * DIMS) != 0) return false;
    const size_t count = vector_bytes.size() / (sizeof(float) * DIMS);
    dataset.vectors.resize(count * DIMS);
    std::memcpy(dataset.vectors.data(), vector_bytes.data(), vector_bytes.size());

    std::vector<uint8_t> labels;
    if (!read_file_bytes(data_dir + "/labels_full.bin", labels)) return false;
    if (labels.size() < count) return false;
    labels.resize(count);
    dataset.labels = std::move(labels);
    return true;
}

static bool load_manifest(const std::string& data_dir, ManifestHeader& manifest) {
    std::vector<uint8_t> bytes;
    if (!read_file_bytes(data_dir + "/manifest.bin", bytes)) return false;
    if (bytes.size() < 5 * sizeof(uint32_t)) return false;
    uint32_t raw[6] = {0, 0, 0, 0, 0, 1};
    const size_t words = std::min<size_t>(6, bytes.size() / sizeof(uint32_t));
    std::memcpy(raw, bytes.data(), words * sizeof(uint32_t));
    manifest.magic = raw[0];
    manifest.version = raw[1];
    manifest.dims = raw[2];
    manifest.k_default = raw[3];
    manifest.bucket_enabled = raw[4];
    manifest.ambiguous_head_enabled = words >= 6 ? raw[5] : 1;
    return manifest.magic == FRAUD_MAGIC && manifest.version == FRAUD_VERSION && manifest.dims == DIMS &&
           manifest.k_default > 0 && manifest.k_default <= K;
}

static bool load_rules(const std::string& data_dir, RulesModel& rules) {
    FILE* f = std::fopen((data_dir + "/rules_model.bin").c_str(), "rb");
    if (!f) return false;
    const bool ok = std::fread(&rules, sizeof(rules), 1, f) == 1;
    std::fclose(f);
    return ok && rules.leaf_count <= MAX_RULE_LEAVES;
}

static bool load_ivf(const std::string& data_dir, IVFIndex& ivf) {
    FILE* f = std::fopen((data_dir + "/ivf_index.bin").c_str(), "rb");
    if (!f) return false;
    int header[2] = {0, 0};
    if (std::fread(header, sizeof(int), 2, f) != 2) { std::fclose(f); return false; }
    ivf.n_clusters = header[0];
    ivf.dims = header[1];
    if (ivf.n_clusters <= 0 || ivf.n_clusters > MAX_CLUSTERS || ivf.dims != DIMS) { std::fclose(f); return false; }
    ivf.centroids.resize(static_cast<size_t>(ivf.n_clusters) * DIMS);
    if (std::fread(ivf.centroids.data(), sizeof(float), ivf.centroids.size(), f) != ivf.centroids.size()) { std::fclose(f); return false; }
    ivf.lists.resize(ivf.n_clusters);
    for (int c = 0; c < ivf.n_clusters; ++c) {
        uint32_t cnt = 0;
        if (std::fread(&cnt, sizeof(uint32_t), 1, f) != 1) { std::fclose(f); return false; }
        ivf.lists[c].resize(cnt);
        if (cnt && std::fread(ivf.lists[c].data(), sizeof(uint32_t), cnt, f) != cnt) { std::fclose(f); return false; }
    }
    std::fclose(f);
    return true;
}

static DirectDecision decide_conservative(const float* v, const RulesModel& r) {
    const uint32_t leaf_count = std::min<uint32_t>(r.leaf_count, MAX_RULE_LEAVES);
    for (uint32_t i = 0; i < leaf_count; ++i) {
        const auto& leaf = r.leaves[i];
        if (leaf.feature_count == 0 || leaf.feature_count > MAX_LEAF_FEATURES) continue;
        bool match = true;
        for (uint8_t j = 0; j < leaf.feature_count; ++j) {
            const uint8_t feature = leaf.features[j];
            if (feature >= DIMS) { match = false; break; }
            const float value = v[feature];
            if (value < leaf.min_values[j] || value > leaf.max_values[j]) { match = false; break; }
        }
        if (!match) continue;
        if (leaf.decision == static_cast<uint8_t>(DirectDecision::CLEAR_LEGIT)) return DirectDecision::CLEAR_LEGIT;
        if (leaf.decision == static_cast<uint8_t>(DirectDecision::CLEAR_FRAUD)) return DirectDecision::CLEAR_FRAUD;
    }

    const float amount_vs_avg = v[2];
    const float km_home = v[7];
    const float mcc_risk = v[12];
    const float unknown_merchant = v[11];
    if (amount_vs_avg <= r.max_amount_vs_avg_legit && km_home <= r.max_km_home_legit && unknown_merchant < 0.5f) return DirectDecision::CLEAR_LEGIT;
    if (amount_vs_avg >= r.min_amount_vs_avg_fraud && km_home >= r.min_km_home_fraud && mcc_risk >= r.min_mcc_risk_fraud) return DirectDecision::CLEAR_FRAUD;
    return DirectDecision::AMBIGUOUS;
}

static float score_exact(const Dataset& dataset, const float* query, int k) {
    float distances[K] = {1e30f, 1e30f, 1e30f, 1e30f, 1e30f};
    uint8_t labels[K] = {0, 0, 0, 0, 0};
    int found = 0;
    for (size_t id = 0; id < dataset.count(); ++id) {
        const float dist = l2_sq(query, &dataset.vectors[id * DIMS]);
        if (found < k) {
            distances[found] = dist;
            labels[found] = dataset.labels[id];
            ++found;
        } else if (dist >= distances[k - 1]) {
            continue;
        } else {
            distances[k - 1] = dist;
            labels[k - 1] = dataset.labels[id];
        }
        for (int j = found < k ? found - 1 : k - 1; j > 0 && distances[j] < distances[j - 1]; --j) {
            std::swap(distances[j], distances[j - 1]);
            std::swap(labels[j], labels[j - 1]);
        }
    }
    int frauds = 0;
    for (int i = 0; i < found; ++i) frauds += labels[i] ? 1 : 0;
    return found ? static_cast<float>(frauds) / static_cast<float>(found) : 0.5f;
}

static int search_ivf(const Dataset& dataset, const IVFIndex& ivf, const float* query, int k, int n_probe_requested, uint8_t* out_labels) {
    struct ClusterDist { int id; float dist; };
    std::array<ClusterDist, MAX_CLUSTERS> cdists;
    for (int c = 0; c < ivf.n_clusters; ++c) cdists[c] = {c, l2_sq(query, &ivf.centroids[c * DIMS])};
    const int n_probe = std::min(n_probe_requested, ivf.n_clusters);
    std::partial_sort(cdists.begin(), cdists.begin() + n_probe, cdists.begin() + ivf.n_clusters,
                      [](const ClusterDist& a, const ClusterDist& b) { return a.dist < b.dist; });

    float best_dists[K] = {1e30f, 1e30f, 1e30f, 1e30f, 1e30f};
    uint8_t best_labels[K] = {0, 0, 0, 0, 0};
    int found = 0;
    for (int i = 0; i < n_probe; ++i) {
        const int c = cdists[i].id;
        for (uint32_t id : ivf.lists[c]) {
            if (id >= dataset.count()) continue;
            const float dist = l2_sq(query, &dataset.vectors[id * DIMS]);
            if (found < k) {
                best_dists[found] = dist;
                best_labels[found] = dataset.labels[id];
                ++found;
            } else if (dist >= best_dists[k - 1]) {
                continue;
            } else {
                best_dists[k - 1] = dist;
                best_labels[k - 1] = dataset.labels[id];
            }
            for (int j = found < k ? found - 1 : k - 1; j > 0 && best_dists[j] < best_dists[j - 1]; --j) {
                std::swap(best_dists[j], best_dists[j - 1]);
                std::swap(best_labels[j], best_labels[j - 1]);
            }
        }
    }
    for (int i = 0; i < found; ++i) out_labels[i] = best_labels[i];
    return found;
}

static float score_ivf(const Dataset& dataset, const IVFIndex& ivf, const float* query, int k, int n_probe, int* out_found) {
    uint8_t labels[K] = {0, 0, 0, 0, 0};
    const int found = search_ivf(dataset, ivf, query, k, n_probe, labels);
    if (out_found) *out_found = found;
    if (found < k) return score_exact(dataset, query, k);
    int frauds = 0;
    for (int i = 0; i < found; ++i) frauds += labels[i] ? 1 : 0;
    return static_cast<float>(frauds) / static_cast<float>(found);
}

static float runtime_boundary_score(float ivf_score) {
    if (ivf_score == 0.4f) return 0.6f;
    if (ivf_score == 0.6f) return 0.4f;
    return ivf_score;
}

static bool approved(float score) {
    return score < 0.6f;
}

static int run_self_test() {
    Dataset dataset{};
    dataset.vectors.resize(5 * DIMS, 0.0f);
    dataset.labels = {1, 1, 1, 0, 0};
    for (int i = 0; i < 5; ++i) dataset.vectors[i * DIMS] = static_cast<float>(i) * 0.01f;
    IVFIndex ivf{};
    ivf.n_clusters = 1;
    ivf.dims = DIMS;
    ivf.centroids.resize(DIMS, 0.0f);
    ivf.lists = {{0, 1, 2, 3, 4}};
    float query[DIMS] = {};
    const float exact = score_exact(dataset, query, K);
    int found = 0;
    const float ivf_score = score_ivf(dataset, ivf, query, K, NPROBE, &found);
    if (found != K || exact != 0.6f || ivf_score != exact || runtime_boundary_score(ivf_score) != 0.4f) {
        std::fprintf(stderr, "self-test: failed exact=%.3f ivf=%.3f found=%d\n", exact, ivf_score, found);
        return 1;
    }
    std::fprintf(stderr, "self-test: ok\n");
    return 0;
}

static void print_usage(const char* argv0) {
    std::fprintf(stderr, "Usage: %s --self-test | --data-dir DIR [--samples N] [--stride N] [--nprobe N] [--only-ambiguous] [--output PATH]\n", argv0);
}

int main(int argc, char** argv) {
    std::string data_dir = "vector-index";
    std::string output_path;
    size_t samples = 200;
    size_t stride = 15485863;
    int nprobe = 8;
    bool self_test = false;
    bool only_ambiguous = false;

    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--self-test") == 0) self_test = true;
        else if (std::strcmp(argv[i], "--data-dir") == 0 && i + 1 < argc) data_dir = argv[++i];
        else if (std::strcmp(argv[i], "--samples") == 0 && i + 1 < argc) samples = std::strtoull(argv[++i], nullptr, 10);
        else if (std::strcmp(argv[i], "--stride") == 0 && i + 1 < argc) stride = std::strtoull(argv[++i], nullptr, 10);
        else if (std::strcmp(argv[i], "--nprobe") == 0 && i + 1 < argc) nprobe = std::atoi(argv[++i]);
        else if (std::strcmp(argv[i], "--only-ambiguous") == 0) only_ambiguous = true;
        else if (std::strcmp(argv[i], "--output") == 0 && i + 1 < argc) output_path = argv[++i];
        else { print_usage(argv[0]); return 1; }
    }
    if (self_test) return run_self_test();

    Dataset dataset{};
    IVFIndex ivf{};
    RulesModel rules{};
    ManifestHeader manifest{};
    if (!load_dataset(data_dir, dataset) || !load_ivf(data_dir, ivf) || !load_rules(data_dir, rules) || !load_manifest(data_dir, manifest)) {
        std::fprintf(stderr, "failed to load artifacts from %s\n", data_dir.c_str());
        return 1;
    }
    if (dataset.count() == 0 || samples == 0 || stride == 0) {
        std::fprintf(stderr, "invalid samples/stride/dataset count\n");
        return 1;
    }

    FILE* out = nullptr;
    if (!output_path.empty()) {
        out = std::fopen(output_path.c_str(), "wb");
        if (!out) {
            std::fprintf(stderr, "failed to open output %s: %s\n", output_path.c_str(), std::strerror(errno));
            return 1;
        }
    }

    Metrics metrics{};
    const int k = static_cast<int>(manifest.k_default);
    for (size_t i = 0, visited = 0; metrics.samples < samples && visited < dataset.count(); ++i, ++visited) {
        const size_t id = (i * stride) % dataset.count();
        const float* query = &dataset.vectors[id * DIMS];
        const DirectDecision direct = decide_conservative(query, rules);
        if (only_ambiguous && direct != DirectDecision::AMBIGUOUS) continue;

        const float exact = score_exact(dataset, query, k);
        int found = 0;
        const float ivf_score = score_ivf(dataset, ivf, query, k, nprobe, &found);
        const float runtime_score = runtime_boundary_score(ivf_score);
        float direct_score = 0.5f;
        if (direct == DirectDecision::CLEAR_LEGIT) direct_score = 0.0f;
        if (direct == DirectDecision::CLEAR_FRAUD) direct_score = 1.0f;

        metrics.samples++;
        if (direct != DirectDecision::AMBIGUOUS) {
            metrics.direct_clear++;
            if (approved(direct_score) != approved(exact)) metrics.direct_clear_exact_disagree++;
        } else {
            metrics.ambiguous++;
        }
        if (std::fabs(ivf_score - exact) > 0.0001f) metrics.ivf_exact_score_disagree++;
        if (approved(ivf_score) != approved(exact)) metrics.ivf_exact_decision_disagree++;
        if (approved(runtime_score) != approved(exact)) metrics.runtime_exact_decision_disagree++;
        if (ivf_score == 0.4f) metrics.boundary_04++;
        if (ivf_score == 0.6f) metrics.boundary_06++;

        const bool any_disagree = (direct != DirectDecision::AMBIGUOUS && approved(direct_score) != approved(exact)) ||
                                  approved(ivf_score) != approved(exact) || approved(runtime_score) != approved(exact) ||
                                  std::fabs(ivf_score - exact) > 0.0001f;
        if (out && any_disagree) {
            std::fprintf(out,
                         "{\"id\":%zu,\"label\":%u,\"direct\":%u,\"exact\":%.3f,\"ivf\":%.3f,\"runtime\":%.3f,\"found\":%d}\n",
                         id, static_cast<unsigned>(dataset.labels[id]), static_cast<unsigned>(direct), exact, ivf_score, runtime_score, found);
        }
    }
    if (out) std::fclose(out);

    std::printf("samples=%lu\n", metrics.samples);
    std::printf("direct_clear=%lu\n", metrics.direct_clear);
    std::printf("direct_clear_exact_disagree=%lu\n", metrics.direct_clear_exact_disagree);
    std::printf("ambiguous=%lu\n", metrics.ambiguous);
    std::printf("ivf_exact_score_disagree=%lu\n", metrics.ivf_exact_score_disagree);
    std::printf("ivf_exact_decision_disagree=%lu\n", metrics.ivf_exact_decision_disagree);
    std::printf("runtime_exact_decision_disagree=%lu\n", metrics.runtime_exact_decision_disagree);
    std::printf("boundary_04=%lu\n", metrics.boundary_04);
    std::printf("boundary_06=%lu\n", metrics.boundary_06);
    std::printf("nprobe=%d\n", nprobe);
    std::printf("only_ambiguous=%s\n", only_ambiguous ? "true" : "false");
    if (!output_path.empty()) std::printf("output=%s\n", output_path.c_str());
    return 0;
}
