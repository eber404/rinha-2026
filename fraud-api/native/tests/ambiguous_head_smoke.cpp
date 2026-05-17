#include "../ambiguous_head.h"

#include <cassert>
#include <cstdio>

static void write_head_fixture(const char* path) {
    AmbiguousHeadModel model{};
    model.magic = AMBIGUOUS_HEAD_MAGIC;
    model.version = AMBIGUOUS_HEAD_VERSION;
    model.feature_count = 4;
    model.bias = 2.0f;
    model.weights[0] = -8.0f;
    model.weights[1] = 0.0f;
    model.weights[2] = 0.0f;
    model.weights[3] = 0.0f;

    FILE* f = std::fopen(path, "wb");
    assert(f != nullptr);
    assert(std::fwrite(&model, sizeof(model), 1, f) == 1);
    assert(std::fclose(f) == 0);
}

int main() {
    const char* path = "/tmp/ambiguous_head_smoke.bin";
    write_head_fixture(path);

    AmbiguousHead head;
    assert(head.load(path));
    const float features[4] = {0.0f, 0.3f, 0.5f, 1.0f};
    const float score = head.infer(features, 4);
    assert(score > 0.88f && score < 0.89f);

    head.close();
    assert(!head.loaded());
    return 0;
}
