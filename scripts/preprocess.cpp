#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>
#include <cstdint>
#include <cmath>
#include <algorithm>
#include <random>
#include <zlib.h>
#include <chrono>
#include <sys/stat.h>

static constexpr int DIMS = 14;
static constexpr int N_CLUSTERS = 4096;
static constexpr int KMEANS_ITERS = 5;
static constexpr uint32_t FRAUD_MAGIC = 0x46445231;
static constexpr uint32_t FRAUD_VERSION = 1;
static constexpr int FRAUD_MAX_RULE_LEAVES = 256;
static constexpr int FRAUD_MAX_LEAF_FEATURES = 4;

struct ManifestHeader {
    uint32_t magic;
    uint32_t version;
    uint32_t dims;
    uint32_t k_default;
    uint32_t bucket_enabled;
    uint32_t ambiguous_head_enabled;
};

struct RulesModelDisk {
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
        uint8_t features[FRAUD_MAX_LEAF_FEATURES];
        uint8_t reserved[2];
        float min_values[FRAUD_MAX_LEAF_FEATURES];
        float max_values[FRAUD_MAX_LEAF_FEATURES];
        uint32_t support;
    } leaves[FRAUD_MAX_RULE_LEAVES];
};

struct Vector {
    float v[DIMS];
    uint8_t label;
};

static inline float l2_sq(const float* a, const float* b) {
    float s = 0.0f;
    for (int i = 0; i < DIMS; ++i) {
        float d = a[i] - b[i];
        s += d * d;
    }
    return s;
}

static bool copy_file(const char* from, const char* to) {
    FILE* in = fopen(from, "rb");
    if (!in) return false;
    FILE* out = fopen(to, "wb");
    if (!out) { fclose(in); return false; }
    char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), in)) > 0) {
        if (fwrite(buf, 1, n, out) != n) { fclose(in); fclose(out); return false; }
    }
    const bool ok = ferror(in) == 0 && fclose(out) == 0;
    fclose(in);
    return ok;
}

static std::vector<Vector> read_binary_vectors(const char* vectors_path, const char* labels_path) {
    FILE* fv = fopen(vectors_path, "rb");
    if (!fv) { perror(vectors_path); exit(1); }
    struct stat st{};
    if (stat(vectors_path, &st) != 0) { perror(vectors_path); exit(1); }
    if (st.st_size <= 0 || st.st_size % (sizeof(float) * DIMS) != 0) {
        fprintf(stderr, "invalid dataset size: %s\n", vectors_path);
        exit(1);
    }
    const size_t count = static_cast<size_t>(st.st_size) / (sizeof(float) * DIMS);
    std::vector<Vector> data(count);
    for (size_t i = 0; i < count; ++i) {
        if (fread(data[i].v, sizeof(float), DIMS, fv) != DIMS) { perror("read vectors"); exit(1); }
    }
    fclose(fv);

    FILE* fl = fopen(labels_path, "rb");
    if (!fl) { perror(labels_path); exit(1); }
    for (size_t i = 0; i < count; ++i) {
        int ch = fgetc(fl);
        if (ch == EOF) { fprintf(stderr, "labels shorter than dataset\n"); exit(1); }
        data[i].label = static_cast<uint8_t>(ch);
    }
    fclose(fl);
    return data;
}

static bool leaf_matches(const Vector& vec, const RulesModelDisk::RuleLeaf& leaf) {
    for (uint8_t i = 0; i < leaf.feature_count; ++i) {
        const uint8_t feature = leaf.features[i];
        if (feature >= DIMS) return false;
        const float value = vec.v[feature];
        if (value < leaf.min_values[i] || value > leaf.max_values[i]) return false;
    }
    return true;
}

static bool validate_leaf(const std::vector<Vector>* data, RulesModelDisk::RuleLeaf& leaf, uint32_t min_support = 32) {
    if (!data) return true;
    uint32_t support = 0;
    for (const auto& vec : *data) {
        if (!leaf_matches(vec, leaf)) continue;
        if (leaf.decision == 0 && vec.label != 0) return false;
        if (leaf.decision == 1 && vec.label != 1) return false;
        ++support;
    }
    leaf.support = support;
    return support >= min_support;
}

static void add_leaf_if_safe(RulesModelDisk& rules, const std::vector<Vector>* data,
                             uint8_t decision, std::initializer_list<uint8_t> features,
                             std::initializer_list<float> mins, std::initializer_list<float> maxs,
                             uint32_t min_support = 32) {
    if (rules.leaf_count >= FRAUD_MAX_RULE_LEAVES) return;
    RulesModelDisk::RuleLeaf leaf{};
    leaf.decision = decision;
    leaf.feature_count = static_cast<uint8_t>(features.size());
    std::copy(features.begin(), features.end(), leaf.features);
    std::copy(mins.begin(), mins.end(), leaf.min_values);
    std::copy(maxs.begin(), maxs.end(), leaf.max_values);
    if (!validate_leaf(data, leaf, min_support)) return;
    rules.leaves[rules.leaf_count++] = leaf;
}

static void mine_safe_leaves(RulesModelDisk& rules, const std::vector<Vector>& data) {
    RulesModelDisk fraud_tmp{}, legit_tmp{};

    // Mine CLEAR_FRAUD - single-feature high-coverage first
    const float amount_min[] = {0.35f, 0.40f, 0.45f, 0.50f, 0.55f, 0.60f, 0.65f, 0.70f, 0.75f, 0.80f, 0.85f, 0.90f, 0.95f};
    const float inst_min[] = {0.60f, 0.65f, 0.70f, 0.75f, 0.80f, 0.85f, 0.90f, 0.95f};
    const float km_last_min[] = {0.35f, 0.40f, 0.45f, 0.50f, 0.55f, 0.60f, 0.65f, 0.70f, 0.75f, 0.80f, 0.85f, 0.90f, 0.95f};
    const float km_home_min[] = {0.40f, 0.45f, 0.50f, 0.55f, 0.60f, 0.65f, 0.70f, 0.75f, 0.80f, 0.85f, 0.90f, 0.95f};
    const float tx24_min[] = {0.55f, 0.60f, 0.65f, 0.70f, 0.75f, 0.80f, 0.85f, 0.90f, 0.95f};
    
    for (float a : amount_min) {
        add_leaf_if_safe(fraud_tmp, &data, 1, {0}, {a}, {1.0f}, 16);
    }
    for (float i : inst_min) {
        add_leaf_if_safe(fraud_tmp, &data, 1, {1}, {i}, {1.0f}, 16);
    }
    for (float k : km_last_min) {
        add_leaf_if_safe(fraud_tmp, &data, 1, {6}, {k}, {1.0f}, 16);
    }
    for (float k : km_home_min) {
        add_leaf_if_safe(fraud_tmp, &data, 1, {7}, {k}, {1.0f}, 16);
    }
    for (float t : tx24_min) {
        add_leaf_if_safe(fraud_tmp, &data, 1, {8}, {t}, {1.0f}, 16);
    }

    // Multi-feature fraud leaves
    const float avga_min[] = {0.60f, 0.70f, 0.80f, 0.90f, 0.95f, 1.0f};
    const float km_min[] = {0.50f, 0.70f, 0.85f, 0.95f, 1.0f};
    const float tx_min[] = {0.40f, 0.60f, 0.80f, 1.0f};
    const float risk_min[] = {0.60f, 0.75f, 0.85f};
    for (float r : avga_min) {
        for (float km : km_min) {
            for (float tx : tx_min) {
                add_leaf_if_safe(fraud_tmp, &data, 1, {2, 7, 8, 11}, {r, km, tx, 1.0f}, {1.0f, 1.0f, 1.0f, 1.0f}, 16);
            }
        }
    }
    for (float r : avga_min) {
        for (float km : km_min) {
            for (float risk : risk_min) {
                add_leaf_if_safe(fraud_tmp, &data, 1, {2, 7, 11, 12}, {r, km, 1.0f, risk}, {1.0f, 1.0f, 1.0f, 1.0f}, 16);
            }
        }
    }

    const float amount_hi[] = {0.70f, 0.80f, 0.90f};
    const float avga_hi[] = {0.70f, 0.85f, 0.95f};
    const float km_hi[] = {0.70f, 0.85f, 0.95f};
    const float tx_hi[] = {0.60f, 0.80f, 0.95f};
    const float inst_hi[] = {0.70f, 0.85f, 0.95f};
    const float risk_hi[] = {0.60f, 0.75f, 0.90f};
    for (float amount : amount_hi) {
        for (float ratio : avga_hi) {
            for (float km : km_hi) {
                for (float tx : tx_hi) {
                    add_leaf_if_safe(fraud_tmp, &data, 1, {0, 2, 7, 8}, {amount, ratio, km, tx}, {1.0f, 1.0f, 1.0f, 1.0f}, 16);
                }
            }
        }
    }
    for (float amount : amount_hi) {
        for (float ratio : avga_hi) {
            for (float km : km_hi) {
                add_leaf_if_safe(fraud_tmp, &data, 1, {0, 2, 7, 11}, {amount, ratio, km, 1.0f}, {1.0f, 1.0f, 1.0f, 1.0f}, 16);
            }
        }
    }
    for (float inst : inst_hi) {
        for (float ratio : avga_hi) {
            for (float km : km_hi) {
                for (float risk : risk_hi) {
                    add_leaf_if_safe(fraud_tmp, &data, 1, {1, 2, 7, 12}, {inst, ratio, km, risk}, {1.0f, 1.0f, 1.0f, 1.0f}, 16);
                }
            }
        }
    }
    for (float ratio : avga_hi) {
        for (float last_km : km_hi) {
            for (float home_km : km_hi) {
                for (float tx : tx_hi) {
                    add_leaf_if_safe(fraud_tmp, &data, 1, {2, 6, 7, 8}, {ratio, last_km, home_km, tx}, {1.0f, 1.0f, 1.0f, 1.0f}, 16);
                }
            }
        }
    }
    for (float ratio : avga_hi) {
        for (float km : km_hi) {
            for (float tx : tx_hi) {
                for (float risk : risk_hi) {
                    add_leaf_if_safe(fraud_tmp, &data, 1, {2, 7, 8, 12}, {ratio, km, tx, risk}, {1.0f, 1.0f, 1.0f, 1.0f}, 16);
                }
            }
        }
    }

    // Mine CLEAR_LEGIT
    const float amount_max[] = {0.02f, 0.03f, 0.05f, 0.08f, 0.10f, 0.15f, 0.20f};
    const float avga_max[] = {0.05f, 0.08f, 0.10f, 0.15f, 0.20f, 0.30f};
    const float km_max[] = {0.03f, 0.05f, 0.08f, 0.10f, 0.15f, 0.20f, 0.30f};
    const float tx_max[] = {0.05f, 0.10f, 0.15f, 0.20f, 0.30f};
    for (float a : amount_max) {
        for (float r : avga_max) {
            for (float km : km_max) {
                add_leaf_if_safe(legit_tmp, &data, 0, {0, 2, 7, 11}, {0.0f, 0.0f, 0.0f, 0.0f}, {a, r, km, 0.0f});
            }
        }
    }
    for (float a : amount_max) {
        for (float r : avga_max) {
            for (float tx : tx_max) {
                add_leaf_if_safe(legit_tmp, &data, 0, {0, 2, 8, 11}, {0.0f, 0.0f, 0.0f, 0.0f}, {a, r, tx, 0.0f});
            }
        }
    }

    const float amount_lo[] = {0.02f, 0.05f, 0.08f, 0.12f};
    const float avga_lo[] = {0.05f, 0.10f, 0.15f};
    const float km_lo[] = {0.03f, 0.08f, 0.15f};
    const float tx_lo[] = {0.05f, 0.10f, 0.20f};
    const float risk_lo[] = {0.10f, 0.25f, 0.40f};
    const float merchant_lo[] = {0.05f, 0.10f, 0.20f};
    for (float amount : amount_lo) {
        for (float ratio : avga_lo) {
            for (float km : km_lo) {
                for (float tx : tx_lo) {
                    add_leaf_if_safe(legit_tmp, &data, 0, {0, 2, 7, 8}, {0.0f, 0.0f, 0.0f, 0.0f}, {amount, ratio, km, tx});
                }
            }
        }
    }
    for (float amount : amount_lo) {
        for (float ratio : avga_lo) {
            for (float km : km_lo) {
                add_leaf_if_safe(legit_tmp, &data, 0, {0, 2, 7, 10}, {0.0f, 0.0f, 0.0f, 1.0f}, {amount, ratio, km, 1.0f});
            }
        }
    }
    for (float amount : amount_lo) {
        for (float ratio : avga_lo) {
            for (float risk : risk_lo) {
                for (float merchant_avg : merchant_lo) {
                    add_leaf_if_safe(legit_tmp, &data, 0, {0, 2, 12, 13}, {0.0f, 0.0f, 0.0f, 0.0f}, {amount, ratio, risk, merchant_avg});
                }
            }
        }
    }

    // Sort each by support descending
    auto sort_by_support = [](RulesModelDisk& tmp) {
        std::vector<RulesModelDisk::RuleLeaf> vec;
        for (uint32_t i = 0; i < tmp.leaf_count; ++i) vec.push_back(tmp.leaves[i]);
        std::sort(vec.begin(), vec.end(), [](const auto& a, const auto& b) { return a.support > b.support; });
        for (size_t i = 0; i < vec.size() && i < (size_t)FRAUD_MAX_RULE_LEAVES; ++i) tmp.leaves[i] = vec[i];
        tmp.leaf_count = std::min(tmp.leaf_count, (uint32_t)FRAUD_MAX_RULE_LEAVES);
    };
    sort_by_support(fraud_tmp);
    sort_by_support(legit_tmp);

    // Merge: take top fraud leaves then top legit leaves
    uint32_t fraud_keep = std::min(fraud_tmp.leaf_count, 96u);
    uint32_t legit_keep = std::min(legit_tmp.leaf_count, (uint32_t)(FRAUD_MAX_RULE_LEAVES - fraud_keep));
    
    rules.leaf_count = 0;
    for (uint32_t i = 0; i < fraud_keep; ++i) {
        rules.leaves[rules.leaf_count++] = fraud_tmp.leaves[i];
    }
    for (uint32_t i = 0; i < legit_keep; ++i) {
        rules.leaves[rules.leaf_count++] = legit_tmp.leaves[i];
    }
}

static bool validate_rules_against_data(const RulesModelDisk& rules, const std::vector<Vector>& data) {
    if (rules.leaf_count > FRAUD_MAX_RULE_LEAVES) return false;
    for (uint32_t i = 0; i < rules.leaf_count; ++i) {
        const auto& leaf = rules.leaves[i];
        if (leaf.feature_count == 0 || leaf.feature_count > FRAUD_MAX_LEAF_FEATURES) return false;
        bool saw_match = false;
        for (const auto& vec : data) {
            if (!leaf_matches(vec, leaf)) continue;
            saw_match = true;
            if (leaf.decision == 0 && vec.label != 0) return false;
            if (leaf.decision == 1 && vec.label != 1) return false;
        }
        if (!saw_match) return false;
    }
    return true;
}

static int run_self_test() {
    if (FRAUD_MAX_RULE_LEAVES < 256) {
        fprintf(stderr, "self-test: expected rule capacity >= 256\n");
        return 1;
    }

    std::vector<Vector> data;
    data.reserve(96);

    for (int i = 0; i < 48; ++i) {
        Vector fraud{};
        fraud.label = 1;
        fraud.v[0] = 0.96f;
        fraud.v[1] = 0.90f;
        fraud.v[2] = 0.95f;
        fraud.v[6] = 0.85f;
        fraud.v[7] = 0.90f;
        fraud.v[8] = 0.85f;
        fraud.v[11] = 1.0f;
        fraud.v[12] = 0.90f;
        data.push_back(fraud);
    }

    for (int i = 0; i < 48; ++i) {
        Vector legit{};
        legit.label = 0;
        legit.v[0] = 0.02f;
        legit.v[2] = 0.04f;
        legit.v[7] = 0.02f;
        legit.v[8] = 0.03f;
        legit.v[10] = 1.0f;
        legit.v[11] = 0.0f;
        legit.v[12] = 0.10f;
        legit.v[13] = 0.05f;
        data.push_back(legit);
    }

    RulesModelDisk rules{};
    mine_safe_leaves(rules, data);
    if (rules.leaf_count == 0) {
        fprintf(stderr, "self-test: expected mined leaves\n");
        return 1;
    }
    if (!validate_rules_against_data(rules, data)) {
        fprintf(stderr, "self-test: unsafe mined leaf\n");
        return 1;
    }
    fprintf(stderr, "self-test: safe_leaves=%u\n", rules.leaf_count);
    return 0;
}

static bool write_metadata_artifacts(const std::vector<Vector>* data = nullptr) {
    RulesModelDisk rules{};
    rules.min_conf_legit = 0.995f;
    rules.min_conf_fraud = 0.995f;
    rules.min_mcc_risk_fraud = 0.90f;
    rules.max_amount_vs_avg_legit = 0.08f;
    rules.min_amount_vs_avg_fraud = 0.98f;
    rules.max_km_home_legit = 0.03f;
    rules.min_km_home_fraud = 0.95f;
    if (data) {
        mine_safe_leaves(rules, *data);
    }
    fprintf(stderr, "Safe rule leaves: %u\n", rules.leaf_count);
    FILE* fr = fopen("vector-index/rules_model.bin", "wb");
    if (!fr) { perror("rules_model.bin"); return false; }
    if (fwrite(&rules, sizeof(rules), 1, fr) != 1) { perror("write rules"); fclose(fr); return false; }
    fclose(fr);

    ManifestHeader mh{};
    mh.magic = FRAUD_MAGIC;
    mh.version = FRAUD_VERSION;
    mh.dims = DIMS;
    mh.k_default = 5;
    mh.bucket_enabled = 0;
    mh.ambiguous_head_enabled = 1;
    FILE* fm = fopen("vector-index/manifest.bin", "wb");
    if (!fm) { perror("manifest.bin"); return false; }
    if (fwrite(&mh, sizeof(mh), 1, fm) != 1) { perror("write manifest"); fclose(fm); return false; }
    fclose(fm);
    return true;
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

static void kmeans(const std::vector<Vector>& data, float* centroids, std::vector<int>& assignments) {
    std::mt19937 rng(42);
    assignments.resize(data.size());
    // Initialize centroids randomly from data points
    for (int c = 0; c < N_CLUSTERS; ++c) {
        int idx = rng() % data.size();
        memcpy(&centroids[c * DIMS], data[idx].v, sizeof(float) * DIMS);
    }
    for (int iter = 0; iter < KMEANS_ITERS; ++iter) {
        auto t1 = std::chrono::high_resolution_clock::now();
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
        auto t2 = std::chrono::high_resolution_clock::now();
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
        auto t3 = std::chrono::high_resolution_clock::now();
        auto assign_ms = std::chrono::duration_cast<std::chrono::milliseconds>(t2 - t1).count();
        auto recompute_ms = std::chrono::duration_cast<std::chrono::milliseconds>(t3 - t2).count();
        fprintf(stderr, "K-means iter %d: assign=%ldms recompute=%ldms\n", iter, assign_ms, recompute_ms);
    }
}

int main(int argc, char** argv) {
    if (argc > 1 && strcmp(argv[1], "--self-test") == 0) {
        return run_self_test();
    }

    if (argc > 1 && strcmp(argv[1], "--metadata-only") == 0) {
        if (!copy_file("vector-index/dataset.bin", "vector-index/dataset_full.bin")) { perror("copy dataset_full.bin"); return 1; }
        if (!copy_file("vector-index/labels.bin", "vector-index/labels_full.bin")) { perror("copy labels_full.bin"); return 1; }
        if (!write_metadata_artifacts()) return 1;
        fprintf(stderr, "Wrote metadata artifacts for existing dataset\n");
        return 0;
    }

    if (argc > 1 && strcmp(argv[1], "--mine-rules") == 0) {
        std::vector<Vector> data = read_binary_vectors("vector-index/dataset_full.bin", "vector-index/labels_full.bin");
        fprintf(stderr, "Loaded %zu binary vectors for rule mining\n", data.size());
        if (!write_metadata_artifacts(&data)) return 1;
        return 0;
    }

    const char* in = (argc > 1) ? argv[1] : ".cache/rinha-official/resources/references.json.gz";
    std::string json = read_gz(in);
    std::vector<Vector> data = parse_json(json);
    fprintf(stderr, "Loaded %zu vectors\n", data.size());

    float centroids[N_CLUSTERS * DIMS];
    std::vector<int> assignments;
    
    auto km_start = std::chrono::high_resolution_clock::now();
    kmeans(data, centroids, assignments);
    auto km_end = std::chrono::high_resolution_clock::now();
    auto km_ms = std::chrono::duration_cast<std::chrono::milliseconds>(km_end - km_start).count();
    fprintf(stderr, "K-means total: %ldms\n", km_ms);

    // Build posting lists and compute reordered indices
    std::vector<std::vector<uint32_t>> lists(N_CLUSTERS);
    for (size_t i = 0; i < data.size(); ++i) {
        lists[assignments[i]].push_back((uint32_t)i);
    }

    // Reorder dataset by cluster for sequential access
    std::vector<Vector> reordered_data;
    std::vector<uint32_t> id_map; // new_idx -> old_idx
    reordered_data.reserve(data.size());
    id_map.reserve(data.size());
    
    for (int c = 0; c < N_CLUSTERS; ++c) {
        for (uint32_t old_idx : lists[c]) {
            reordered_data.push_back(data[old_idx]);
            id_map.push_back(old_idx);
        }
    }
    
    // Update lists to use new indices
    size_t offset = 0;
    for (int c = 0; c < N_CLUSTERS; ++c) {
        for (size_t i = 0; i < lists[c].size(); ++i) {
            lists[c][i] = offset++;
        }
    }

    FILE* fv = fopen("vector-index/dataset_full.bin", "wb");
    if (!fv) { perror("dataset.bin"); return 1; }
    for (const auto& vec : reordered_data) {
        if (fwrite(vec.v, sizeof(float), DIMS, fv) != DIMS) { perror("write dataset"); return 1; }
    }
    fclose(fv);

    FILE* fl = fopen("vector-index/labels_full.bin", "wb");
    if (!fl) { perror("labels.bin"); return 1; }
    for (const auto& vec : reordered_data) {
        if (fputc(vec.label, fl) == EOF) { perror("write label"); return 1; }
    }
    fclose(fl);

    FILE* fv_compat = fopen("vector-index/dataset.bin", "wb");
    if (!fv_compat) { perror("dataset.bin"); return 1; }
    for (const auto& vec : reordered_data) {
        if (fwrite(vec.v, sizeof(float), DIMS, fv_compat) != DIMS) { perror("write dataset compat"); return 1; }
    }
    fclose(fv_compat);

    FILE* fl_compat = fopen("vector-index/labels.bin", "wb");
    if (!fl_compat) { perror("labels.bin"); return 1; }
    for (const auto& vec : reordered_data) {
        if (fputc(vec.label, fl_compat) == EOF) { perror("write label compat"); return 1; }
    }
    fclose(fl_compat);

    FILE* fi = fopen("vector-index/ivf_index.bin", "wb");
    if (!fi) { perror("ivf_index.bin"); return 1; }
    int header[2] = {N_CLUSTERS, DIMS};
    if (fwrite(header, sizeof(int), 2, fi) != 2) { perror("write header"); return 1; }
    if (fwrite(centroids, sizeof(float), N_CLUSTERS * DIMS, fi) != (size_t)(N_CLUSTERS * DIMS)) { perror("write centroids"); return 1; }
    for (int c = 0; c < N_CLUSTERS; ++c) {
        uint32_t cnt = (uint32_t)lists[c].size();
        if (fwrite(&cnt, sizeof(uint32_t), 1, fi) != 1) { perror("write count"); return 1; }
        if (cnt && fwrite(lists[c].data(), sizeof(uint32_t), cnt, fi) != cnt) { perror("write list"); return 1; }
    }
    fclose(fi);

    if (!write_metadata_artifacts(&reordered_data)) return 1;

    fprintf(stderr, "Wrote dataset_full.bin, labels_full.bin, ivf_index.bin, rules_model.bin, manifest.bin\n");
    return 0;
}
