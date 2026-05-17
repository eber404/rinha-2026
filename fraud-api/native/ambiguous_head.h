#pragma once

#include <cstdint>

static constexpr uint32_t AMBIGUOUS_HEAD_MAGIC = 0x414D4231;
static constexpr uint32_t AMBIGUOUS_HEAD_VERSION = 1;
static constexpr uint32_t AMBIGUOUS_HEAD_MAX_FEATURES = 4;

struct AmbiguousHeadModel {
    uint32_t magic = AMBIGUOUS_HEAD_MAGIC;
    uint32_t version = AMBIGUOUS_HEAD_VERSION;
    uint32_t feature_count = 0;
    uint32_t reserved = 0;
    float bias = 0.0f;
    float weights[AMBIGUOUS_HEAD_MAX_FEATURES] = {0.0f, 0.0f, 0.0f, 0.0f};
};

class AmbiguousHead {
public:
    bool load(const char* path);
    float infer(const float* features, uint32_t feature_count) const;
    bool loaded() const { return loaded_; }
    uint32_t feature_count() const { return model_.feature_count; }
    void close();

private:
    AmbiguousHeadModel model_{};
    bool loaded_ = false;
};
