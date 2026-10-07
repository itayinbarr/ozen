#include "ozen_ort.h"

#include <onnxruntime/coreml_provider_factory.h>
#include <onnxruntime/onnxruntime_cxx_api.h>

#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

void writeError(char *err, size_t errLen, const char *msg) {
    if (err && errLen > 0) {
        std::snprintf(err, errLen, "%s", msg);
    }
}

Ort::Env &sharedEnv() {
    static Ort::Env env(ORT_LOGGING_LEVEL_WARNING, "ozen");
    return env;
}

}  // namespace

struct OzenOrt {
    Ort::Session encoder{nullptr};
    Ort::Session decoder{nullptr};
    Ort::MemoryInfo cpu = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

    // Decoder graph layout.
    int layers = 0;
    int64_t heads = 8;
    int64_t headDim = 64;
    std::vector<std::string> inputNames;   // owned, in session order
    std::vector<const char *> inputPtrs;   // view of inputNames
    int inputIdsIndex = -1, hiddenIndex = -1, cacheBranchIndex = -1;
    // For each decoder input that is a past KV: slot in `past` (layer*4 + kind*2 + kv), else -1.
    std::vector<int> pastSlot;
    std::vector<std::string> outputNamesFirst;  // logits + all present.*
    std::vector<std::string> outputNamesLater;  // logits + present.*.decoder.*
    std::vector<const char *> outputPtrsFirst, outputPtrsLater;

    // Per-window state.
    Ort::Value hidden{nullptr};
    std::vector<Ort::Value> past;  // layers*4: [L][decoder,encoder][key,value]
    Ort::Value emptyPast{nullptr};
    float emptyDummy = 0;
    int64_t tokenBuf = 0;
    bool cacheBranch = false;
    Ort::Value tokenValue{nullptr};
    Ort::Value cacheValue{nullptr};
    int step = 0;
};

static int slotFor(int layer, int kind, int kv) { return layer * 4 + kind * 2 + kv; }

extern "C" OzenOrt *ozen_ort_create(const char *encoderPath, const char *decoderPath, OzenOrtOptions options,
                                    char *err, size_t errLen) {
    try {
        auto o = std::make_unique<OzenOrt>();
        auto makeOptions = [&](int provider, int which) {
            const bool coreml = provider == 1 || provider == 2;
            Ort::SessionOptions so;
            if (!options.arena[which]) so.DisableCpuMemArena();
            if (!options.memPattern[which]) so.DisableMemPattern();
            if (!options.prepacking[which]) so.AddConfigEntry("session.disable_prepacking", "1");
            if (options.intraOpThreads > 0) so.SetIntraOpNumThreads(options.intraOpThreads);
            so.SetInterOpNumThreads(1);
            so.SetExecutionMode(ORT_SEQUENTIAL);
            so.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
            if (coreml) {
                std::unordered_map<std::string, std::string> p;
                p[kCoremlProviderOption_ModelFormat] = options.encoderProvider == 2 ? "NeuralNetwork" : "MLProgram";
                p[kCoremlProviderOption_MLComputeUnits] =
                    options.coreMLComputeUnits ? options.coreMLComputeUnits : "ALL";
                p[kCoremlProviderOption_RequireStaticInputShapes] = "0";
                p[kCoremlProviderOption_EnableOnSubgraphs] = "0";
                if (options.coreMLCacheDirectory && options.coreMLCacheDirectory[0]) {
                    p[kCoremlProviderOption_ModelCacheDirectory] = options.coreMLCacheDirectory;
                }
                so.AppendExecutionProvider("CoreML", p);
            }

            return so;
        };

        try {
            Ort::SessionOptions so = makeOptions(options.encoderProvider, 0);
            o->encoder = Ort::Session(sharedEnv(), encoderPath, so);
        } catch (const std::exception &e) {
            throw std::runtime_error(std::string("encoder: ") + e.what());
        }
        try {
            Ort::SessionOptions so = makeOptions(0, 1);
            o->decoder = Ort::Session(sharedEnv(), decoderPath, so);
        } catch (const std::exception &e) {
            throw std::runtime_error(std::string("decoder: ") + e.what());
        }

        Ort::AllocatorWithDefaultOptions alloc;
        size_t nIn = o->decoder.GetInputCount();
        for (size_t i = 0; i < nIn; i++) {
            o->inputNames.emplace_back(o->decoder.GetInputNameAllocated(i, alloc).get());
        }
        for (auto &n : o->inputNames) {
            const std::string suffix = ".decoder.key";
            if (n.size() > suffix.size() && n.compare(n.size() - suffix.size(), suffix.size(), suffix) == 0) {
                o->layers++;
            }
        }
        if (o->layers == 0) throw std::runtime_error("decoder: no past_key_values inputs");
        o->pastSlot.assign(nIn, -1);
        for (size_t i = 0; i < nIn; i++) {
            const std::string &n = o->inputNames[i];
            if (n == "input_ids") o->inputIdsIndex = (int)i;
            else if (n == "encoder_hidden_states") o->hiddenIndex = (int)i;
            else if (n == "use_cache_branch") o->cacheBranchIndex = (int)i;
            else {
                bool matched = false;
                for (int l = 0; l < o->layers && !matched; l++) {
                    for (int k = 0; k < 2 && !matched; k++) {
                        for (int v = 0; v < 2 && !matched; v++) {
                            std::string want = "past_key_values." + std::to_string(l) + (k == 0 ? ".decoder." : ".encoder.") +
                                               (v == 0 ? "key" : "value");
                            if (n == want) {
                                o->pastSlot[i] = slotFor(l, k, v);
                                matched = true;
                            }
                        }
                    }
                }
                if (!matched) throw std::runtime_error("decoder: unexpected input " + n);
                if (o->pastSlot[i] == 0) {
                    auto shape = o->decoder.GetInputTypeInfo(i).GetTensorTypeAndShapeInfo().GetShape();
                    if (shape.size() == 4) {
                        if (shape[1] > 0) o->heads = shape[1];
                        if (shape[3] > 0) o->headDim = shape[3];
                    }
                }
            }
        }
        if (o->inputIdsIndex < 0 || o->hiddenIndex < 0 || o->cacheBranchIndex < 0) {
            throw std::runtime_error("decoder: missing input_ids / encoder_hidden_states / use_cache_branch");
        }
        for (auto &n : o->inputNames) o->inputPtrs.push_back(n.c_str());

        o->outputNamesFirst.push_back("logits");
        o->outputNamesLater.push_back("logits");
        for (int l = 0; l < o->layers; l++) {
            for (int k = 0; k < 2; k++) {
                for (int v = 0; v < 2; v++) {
                    std::string name = "present." + std::to_string(l) + (k == 0 ? ".decoder." : ".encoder.") +
                                       (v == 0 ? "key" : "value");
                    o->outputNamesFirst.push_back(name);
                    if (k == 0) o->outputNamesLater.push_back(name);
                }
            }
        }
        for (auto &n : o->outputNamesFirst) o->outputPtrsFirst.push_back(n.c_str());
        for (auto &n : o->outputNamesLater) o->outputPtrsLater.push_back(n.c_str());

        int64_t emptyShape[4] = {1, o->heads, 0, o->headDim};
        o->emptyPast = Ort::Value::CreateTensor<float>(o->cpu, &o->emptyDummy, 0, emptyShape, 4);
        int64_t idShape[2] = {1, 1};
        o->tokenValue = Ort::Value::CreateTensor<int64_t>(o->cpu, &o->tokenBuf, 1, idShape, 2);
        int64_t boolShape[1] = {1};
        o->cacheValue = Ort::Value::CreateTensor<bool>(o->cpu, &o->cacheBranch, 1, boolShape, 1);
        o->past.reserve(o->layers * 4);
        for (int i = 0; i < o->layers * 4; i++) o->past.emplace_back(nullptr);
        return o.release();
    } catch (const std::exception &e) {
        writeError(err, errLen, e.what());
        return nullptr;
    }
}

extern "C" void ozen_ort_destroy(OzenOrt *ort) { delete ort; }

extern "C" void ozen_ort_end_window(OzenOrt *o) {
    o->hidden = Ort::Value(nullptr);
    for (auto &p : o->past) p = Ort::Value(nullptr);
    o->step = 0;
}

extern "C" int32_t ozen_ort_encode(OzenOrt *o, const float *features, char *err, size_t errLen) {
    try {
        ozen_ort_end_window(o);
        int64_t shape[3] = {1, 80, 3000};
        Ort::Value input =
            Ort::Value::CreateTensor<float>(o->cpu, const_cast<float *>(features), 80 * 3000, shape, 3);
        const char *inName = "input_features";
        const char *outName = "last_hidden_state";
        auto out = o->encoder.Run(Ort::RunOptions{nullptr}, &inName, &input, 1, &outName, 1);
        o->hidden = std::move(out[0]);
        return 0;
    } catch (const std::exception &e) {
        writeError(err, errLen, e.what());
        return 1;
    }
}

extern "C" int32_t ozen_ort_step(OzenOrt *o, int64_t token, int32_t *next, char *err, size_t errLen) {
    try {
        if (!o->hidden) throw std::runtime_error("ozen_ort_step before ozen_ort_encode");
        const bool first = o->step == 0;
        o->tokenBuf = token;
        o->cacheBranch = !first;

        const size_t nIn = o->inputNames.size();
        std::vector<const OrtValue *> inputs(nIn, nullptr);
        for (size_t i = 0; i < nIn; i++) {
            if ((int)i == o->inputIdsIndex) inputs[i] = o->tokenValue;
            else if ((int)i == o->hiddenIndex) inputs[i] = o->hidden;
            else if ((int)i == o->cacheBranchIndex) inputs[i] = o->cacheValue;
            else inputs[i] = first ? (const OrtValue *)o->emptyPast : (const OrtValue *)o->past[o->pastSlot[i]];
        }

        const auto &outPtrs = first ? o->outputPtrsFirst : o->outputPtrsLater;
        std::vector<OrtValue *> outputs(outPtrs.size(), nullptr);
        Ort::ThrowOnError(Ort::GetApi().Run(o->decoder, nullptr, o->inputPtrs.data(), inputs.data(), nIn,
                                            outPtrs.data(), outPtrs.size(), outputs.data()));
        // Take ownership of everything ORT allocated.
        std::vector<Ort::Value> owned;
        owned.reserve(outputs.size());
        for (auto *v : outputs) owned.emplace_back(v);

        auto info = owned[0].GetTensorTypeAndShapeInfo();
        auto shape = info.GetShape();
        const int64_t vocab = shape.back();
        const int64_t total = (int64_t)info.GetElementCount();
        const float *logits = owned[0].GetTensorData<float>() + (total - vocab);  // last position
        int32_t best = 0;
        float bestVal = logits[0];
        for (int64_t i = 1; i < vocab; i++) {
            if (logits[i] > bestVal) {  // strict: first max wins, like np.argmax
                bestVal = logits[i];
                best = (int32_t)i;
            }
        }
        *next = best;

        // Carry the caches: present.*.decoder.* every step, present.*.encoder.* from step 0 only.
        size_t idx = 1;
        for (int l = 0; l < o->layers; l++) {
            for (int k = 0; k < 2; k++) {
                if (k == 1 && !first) continue;
                for (int v = 0; v < 2; v++) {
                    o->past[slotFor(l, k, v)] = std::move(owned[idx++]);
                }
            }
        }
        o->step++;
        return 0;
    } catch (const std::exception &e) {
        writeError(err, errLen, e.what());
        return 1;
    }
}
