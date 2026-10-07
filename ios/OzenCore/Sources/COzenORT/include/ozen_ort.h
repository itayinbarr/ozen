#ifndef OZEN_ORT_H
#define OZEN_ORT_H

// Thin C wrapper over the ONNX Runtime C++ API for Ozen's Whisper encoder +
// merged decoder. The Objective-C bindings shipped in onnxruntime-swift-package-manager
// cannot create bool tensors, which the merged decoder's `use_cache_branch`
// input requires, so the ORT calls live here instead.

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OzenOrt OzenOrt;

typedef struct {
    /// Intra-op threads for both sessions (0 = ORT default).
    int32_t intraOpThreads;
    /// Encoder execution provider: 0 = CPU; 1 = CoreML (MLProgram); 2 = CoreML (NeuralNetwork).
    int32_t encoderProvider;
    /// CoreML compute units: "ALL", "CPUAndNeuralEngine", "CPUAndGPU", "CPUOnly" (NULL = ALL).
    const char *_Nullable coreMLComputeUnits;
    /// Directory where CoreML caches the compiled encoder (NULL = no cache).
    const char *_Nullable coreMLCacheDirectory;
    /// Per-session memory settings ([0] encoder, [1] decoder), each 0/1:
    /// CPU memory arena (keeps peak activation memory between runs), weight
    /// pre-packing (faster MatMul, extra copy of weights), memory-pattern planning.
    int32_t arena[2];
    int32_t prepacking[2];
    int32_t memPattern[2];
} OzenOrtOptions;

/// Loads both sessions. Returns NULL and writes a message into `err` on failure.
OzenOrt *_Nullable ozen_ort_create(const char *_Nonnull encoderPath, const char *_Nonnull decoderPath,
                                   OzenOrtOptions options, char *_Nullable err, size_t errLen);

void ozen_ort_destroy(OzenOrt *_Nullable ort);

/// Runs the encoder on log-mel features laid out [80][3000] float32 and starts a
/// new decode (the next ozen_ort_step is step 0). Returns 0 on success.
int32_t ozen_ort_encode(OzenOrt *_Nonnull ort, const float *_Nonnull features, char *_Nullable err, size_t errLen);

/// One greedy decoder step: feeds `token`, writes argmax of the logits to `next`.
/// Returns 0 on success.
int32_t ozen_ort_step(OzenOrt *_Nonnull ort, int64_t token, int32_t *_Nonnull next, char *_Nullable err,
                      size_t errLen);

/// Frees the per-window state (encoder hidden states and KV caches).
void ozen_ort_end_window(OzenOrt *_Nonnull ort);

#ifdef __cplusplus
}
#endif

#endif
