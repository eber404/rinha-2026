#include "ambiguous_head.h"

#include <algorithm>
#include <cmath>
#include <cstdio>

bool AmbiguousHead::load(const char* path) {
    close();
    if (!path || path[0] == '\0') return false;
    FILE* f = std::fopen(path, "rb");
    if (!f) return false;

    AmbiguousHeadModel model{};
    const bool ok = std::fread(&model, sizeof(model), 1, f) == 1;
    std::fclose(f);
    if (!ok) return false;
    if (model.magic != AMBIGUOUS_HEAD_MAGIC) return false;
    if (model.version != AMBIGUOUS_HEAD_VERSION) return false;
    if (model.feature_count == 0 || model.feature_count > AMBIGUOUS_HEAD_MAX_FEATURES) return false;
    if (!std::isfinite(model.bias)) return false;
    for (uint32_t i = 0; i < model.feature_count; ++i) {
        if (!std::isfinite(model.weights[i])) return false;
    }

    model_ = model;
    loaded_ = true;
    return true;
}

float AmbiguousHead::infer(const float* features, uint32_t feature_count) const {
    if (!loaded_ || !features) return 0.5f;
    const uint32_t n = std::min(feature_count, model_.feature_count);
    float z = model_.bias;
    for (uint32_t i = 0; i < n; ++i) {
        if (!std::isfinite(features[i])) return 0.5f;
        z += model_.weights[i] * features[i];
    }
    if (!std::isfinite(z)) return 0.5f;
    const float s = 1.0f / (1.0f + std::exp(-z));
    if (!std::isfinite(s)) return 0.5f;
    if (s < 0.0f) return 0.0f;
    if (s > 1.0f) return 1.0f;
    return s;
}

void AmbiguousHead::close() {
    model_ = AmbiguousHeadModel{};
    loaded_ = false;
}
