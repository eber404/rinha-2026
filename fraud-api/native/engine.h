#pragma once

#include <cstdint>
#include <cstddef>

static constexpr uint32_t FRAUD_MAGIC = 0x46445231;
static constexpr uint32_t FRAUD_VERSION = 1;
static constexpr int FRAUD_DIMS = 14;
static constexpr int FRAUD_MAX_RULE_LEAVES = 128;
static constexpr int FRAUD_MAX_LEAF_FEATURES = 4;

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
        uint8_t features[FRAUD_MAX_LEAF_FEATURES];
        uint8_t reserved[2];
        float min_values[FRAUD_MAX_LEAF_FEATURES];
        float max_values[FRAUD_MAX_LEAF_FEATURES];
        uint32_t support;
    } leaves[FRAUD_MAX_RULE_LEAVES];
};

struct ManifestHeader {
    uint32_t magic;
    uint32_t version;
    uint32_t dims;
    uint32_t k_default;
    uint32_t bucket_enabled;
};

struct RuntimeCounters {
    uint64_t clear_legit = 0;
    uint64_t clear_fraud = 0;
    uint64_t ambiguous = 0;
    uint64_t fallback_bucket = 0;
    uint64_t fallback_full = 0;
    uint64_t fallback_ivf = 0;
    uint64_t refinement_exact = 0;
    uint64_t refinement_changed = 0;
    uint64_t sample_exact = 0;
    uint64_t sample_disagree = 0;
};
