#include "knn.h"

static KNNEngine g_engine;

extern "C" int fraud_init(const char* dataset_path) {
    return g_engine.load(dataset_path) ? 0 : -1;
}

extern "C" float fraud_score(const float* vector14) {
    return g_engine.score(vector14);
}

extern "C" void fraud_close() {
    g_engine.close();
}
