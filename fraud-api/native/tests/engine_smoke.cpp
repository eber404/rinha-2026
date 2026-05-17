#include "../knn.h"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sys/stat.h>

struct TestAmbiguousHead {
    uint32_t magic;
    uint32_t version;
    uint32_t feature_count;
    uint32_t reserved;
    float bias;
    float weights[4];
};

struct TestManifest {
    uint32_t magic;
    uint32_t version;
    uint32_t dims;
    uint32_t k_default;
    uint32_t bucket_enabled;
};

struct TestManifestV2 {
    uint32_t magic;
    uint32_t version;
    uint32_t dims;
    uint32_t k_default;
    uint32_t bucket_enabled;
    uint32_t ambiguous_head_enabled;
};

struct TestRules {
    float min_conf_legit;
    float min_conf_fraud;
    float min_mcc_risk_fraud;
    float max_amount_vs_avg_legit;
    float min_amount_vs_avg_fraud;
    float max_km_home_legit;
    float min_km_home_fraud;
    uint32_t leaf_count;
    RulesModel::RuleLeaf leaves[128];
};

static void write_file(const char* path, const void* data, size_t size) {
    FILE* f = std::fopen(path, "wb");
    assert(f != nullptr);
    assert(std::fwrite(data, 1, size, f) == size);
    assert(std::fclose(f) == 0);
}

static void write_fixture(const char* dir, bool manifest) {
    mkdir(dir, 0777);
    float vectors[5][14] = {};
    uint8_t labels[5] = {0, 1, 0, 1, 0};
    int header[2] = {1, 14};
    float centroid[14] = {};
    uint32_t count = 5;
    uint32_t ids[5] = {0, 1, 2, 3, 4};

    char path[256];
    std::snprintf(path, sizeof(path), "%s/dataset.bin", dir);
    write_file(path, vectors, sizeof(vectors));
    std::snprintf(path, sizeof(path), "%s/labels.bin", dir);
    write_file(path, labels, sizeof(labels));
    std::snprintf(path, sizeof(path), "%s/ivf_index.bin", dir);
    FILE* f = std::fopen(path, "wb");
    assert(f != nullptr);
    assert(std::fwrite(header, sizeof(int), 2, f) == 2);
    assert(std::fwrite(centroid, sizeof(float), 14, f) == 14);
    assert(std::fwrite(&count, sizeof(uint32_t), 1, f) == 1);
    assert(std::fwrite(ids, sizeof(uint32_t), 5, f) == 5);
    assert(std::fclose(f) == 0);

    if (manifest) {
        TestManifest mh{0x46445231, 1, 14, 5, 0};
        TestRules rules{};
        rules.min_conf_legit = 0.995f;
        rules.min_conf_fraud = 0.995f;
        rules.min_mcc_risk_fraud = 0.90f;
        rules.max_amount_vs_avg_legit = 0.08f;
        rules.min_amount_vs_avg_fraud = 0.98f;
        rules.max_km_home_legit = 0.03f;
        rules.min_km_home_fraud = 0.95f;
        std::snprintf(path, sizeof(path), "%s/manifest.bin", dir);
        write_file(path, &mh, sizeof(mh));
        std::snprintf(path, sizeof(path), "%s/rules_model.bin", dir);
        write_file(path, &rules, sizeof(rules));
    }
}

static void write_full_fallback_fixture(const char* dir) {
    mkdir(dir, 0777);
    static constexpr int total = 10001;
    uint8_t labels[total] = {};
    labels[5] = 1;
    int header[2] = {1, 14};
    float centroid[14] = {};
    uint32_t count = 5;
    uint32_t ids[5] = {0, 1, 2, 3, 4};
    TestManifest mh{0x46445231, 1, 14, 5, 0};
    TestRules rules{};
    rules.min_conf_legit = 0.995f;
    rules.min_conf_fraud = 0.995f;
    rules.min_mcc_risk_fraud = 0.90f;
    rules.max_amount_vs_avg_legit = 0.08f;
    rules.min_amount_vs_avg_fraud = 0.98f;
    rules.max_km_home_legit = 0.03f;
    rules.min_km_home_fraud = 0.95f;

    char path[256];
    std::snprintf(path, sizeof(path), "%s/dataset.bin", dir);
    FILE* df = std::fopen(path, "wb");
    assert(df != nullptr);
    for (int i = 0; i < total; ++i) {
        float row[14] = {};
        row[2] = 0.5f + static_cast<float>(i % 6) * 0.01f;
        row[7] = 0.5f + static_cast<float>(i % 6) * 0.01f;
        row[12] = 0.5f;
        row[11] = 1.0f;
        assert(std::fwrite(row, sizeof(float), 14, df) == 14);
    }
    assert(std::fclose(df) == 0);
    std::snprintf(path, sizeof(path), "%s/labels.bin", dir);
    write_file(path, labels, sizeof(labels));
    std::snprintf(path, sizeof(path), "%s/manifest.bin", dir);
    write_file(path, &mh, sizeof(mh));
    std::snprintf(path, sizeof(path), "%s/rules_model.bin", dir);
    write_file(path, &rules, sizeof(rules));
    std::snprintf(path, sizeof(path), "%s/ivf_index.bin", dir);
    FILE* f = std::fopen(path, "wb");
    assert(f != nullptr);
    assert(std::fwrite(header, sizeof(int), 2, f) == 2);
    assert(std::fwrite(centroid, sizeof(float), 14, f) == 14);
    assert(std::fwrite(&count, sizeof(uint32_t), 1, f) == 1);
    assert(std::fwrite(ids, sizeof(uint32_t), 5, f) == 5);
    assert(std::fclose(f) == 0);
}

static void write_ambiguous_head_fixture(const char* dir) {
    TestAmbiguousHead head{};
    head.magic = 0x414D4231;
    head.version = 1;
    head.feature_count = 4;
    head.bias = 2.0f;
    head.weights[0] = -8.0f;
    head.weights[1] = 0.0f;
    head.weights[2] = 0.0f;
    head.weights[3] = 0.0f;
    char path[256];
    std::snprintf(path, sizeof(path), "%s/ambiguous_head.bin", dir);
    write_file(path, &head, sizeof(head));
}

static void write_manifest_v2_disable_head_fixture(const char* dir) {
    write_full_fallback_fixture(dir);
    write_ambiguous_head_fixture(dir);
    TestManifestV2 mh{0x46445231, 1, 14, 5, 0, 0};
    char path[256];
    std::snprintf(path, sizeof(path), "%s/manifest.bin", dir);
    write_file(path, &mh, sizeof(mh));
}

int main() {
    assert(fraud_init("/tmp/does-not-exist") != 0);
    fraud_close();
    float q[14] = {0};
    const float s = fraud_score(q);
    assert(s >= 0.0f && s <= 1.0f);

    write_fixture("/tmp/fraud_missing_manifest", false);
    assert(fraud_init("/tmp/fraud_missing_manifest") != 0);

    write_fixture("/tmp/fraud_valid_manifest", true);
    assert(fraud_init("/tmp/fraud_valid_manifest") == 0);
    float q_legit[14] = {0.01f, 0.0f, 0.01f, 0.2f, 0.1f, -1.0f, -1.0f, 0.01f, 0.0f, 0.0f, 1.0f, 0.0f, 0.1f, 0.01f};
    float q_fraud[14] = {1.0f, 1.0f, 1.0f, 0.8f, 0.9f, -1.0f, -1.0f, 1.0f, 1.0f, 1.0f, 0.0f, 1.0f, 1.0f, 1.0f};
    assert(fraud_score(q_legit) <= 0.1f);
    assert(fraud_score(q_fraud) >= 0.9f);
    fraud_close();

    write_fixture("/tmp/fraud_leaf_manifest", true);
    TestRules leaf_rules{};
    leaf_rules.min_conf_legit = 0.995f;
    leaf_rules.min_conf_fraud = 0.995f;
    leaf_rules.min_mcc_risk_fraud = 0.90f;
    leaf_rules.max_amount_vs_avg_legit = 0.0f;
    leaf_rules.min_amount_vs_avg_fraud = 1.1f;
    leaf_rules.max_km_home_legit = 0.0f;
    leaf_rules.min_km_home_fraud = 1.1f;
    leaf_rules.leaf_count = 1;
    leaf_rules.leaves[0].decision = static_cast<uint8_t>(DirectDecision::CLEAR_LEGIT);
    leaf_rules.leaves[0].feature_count = 2;
    leaf_rules.leaves[0].features[0] = 2;
    leaf_rules.leaves[0].features[1] = 11;
    leaf_rules.leaves[0].min_values[0] = 0.30f;
    leaf_rules.leaves[0].max_values[0] = 0.60f;
    leaf_rules.leaves[0].min_values[1] = 1.0f;
    leaf_rules.leaves[0].max_values[1] = 1.0f;
    char leaf_path[256];
    std::snprintf(leaf_path, sizeof(leaf_path), "%s/rules_model.bin", "/tmp/fraud_leaf_manifest");
    write_file(leaf_path, &leaf_rules, sizeof(leaf_rules));
    assert(fraud_init("/tmp/fraud_leaf_manifest") == 0);
    float q_leaf[14] = {};
    q_leaf[2] = 0.5f;
    q_leaf[11] = 1.0f;
    assert(fraud_score(q_leaf) == 0.0f);
    fraud_close();

    write_full_fallback_fixture("/tmp/fraud_full_fallback");
    assert(fraud_init("/tmp/fraud_full_fallback") == 0);
    float q_amb[14] = {};
    q_amb[2] = 0.55f;
    q_amb[7] = 0.55f;
    q_amb[11] = 1.0f;
    q_amb[12] = 0.5f;
    assert(fraud_score(q_amb) == 0.0f);
    fraud_close();

    write_full_fallback_fixture("/tmp/fraud_with_ambiguous_head");
    write_ambiguous_head_fixture("/tmp/fraud_with_ambiguous_head");
    setenv("FRAUD_AMBIGUOUS_HEAD", "on", 1);
    assert(fraud_init("/tmp/fraud_with_ambiguous_head") == 0);
    float q_head[14] = {};
    q_head[2] = 0.55f;
    q_head[7] = 0.55f;
    q_head[11] = 1.0f;
    q_head[12] = 0.5f;
    const float score_with_head = fraud_score(q_head);
    assert(score_with_head > 0.8f);
    fraud_close();

    setenv("FRAUD_AMBIGUOUS_HEAD", "off", 1);
    assert(fraud_init("/tmp/fraud_with_ambiguous_head") == 0);
    const float score_without_head = fraud_score(q_head);
    fraud_close();
    assert(score_without_head == 0.0f);

    setenv("FRAUD_AMBIGUOUS_HEAD", "maybe", 1);
    assert(fraud_init("/tmp/fraud_with_ambiguous_head") == 0);
    const float score_invalid_env = fraud_score(q_head);
    fraud_close();
    assert(score_invalid_env == score_without_head);

    unsetenv("FRAUD_AMBIGUOUS_HEAD");
    assert(fraud_init("/tmp/fraud_full_fallback") == 0);
    const float score_without_artifact = fraud_score(q_head);
    fraud_close();
    assert(score_without_artifact == score_without_head);

    write_manifest_v2_disable_head_fixture("/tmp/fraud_v2_manifest_head_off");
    unsetenv("FRAUD_AMBIGUOUS_HEAD");
    assert(fraud_init("/tmp/fraud_v2_manifest_head_off") == 0);
    const float score_manifest_v2_head_off = fraud_score(q_head);
    fraud_close();
    assert(score_manifest_v2_head_off == score_without_head);
    return 0;
}
