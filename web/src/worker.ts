/**
 * Transcription worker. Owns ONNX Runtime, the model sessions and the engine;
 * the page only sends PCM and receives segments.
 *
 * Backend: WebGPU when the browser has an adapter with shader-f16 (the encoder
 * is fp16), otherwise single-threaded WASM. See README "Threading" for why we do
 * not enable cross-origin isolation for multi-threaded WASM.
 */

/// <reference lib="webworker" />

import type * as Ort from 'onnxruntime-web'
import { MODEL_FILES } from './engine/constants.ts'
import { parseMelFilters } from './engine/mel.ts'
import { AbortedError, Transcriber, type Segment } from './engine/model.ts'
import { clearModelCache, loadModelFiles, ModelDownloadError, type LoadProgress } from './engine/store.ts'
import { Tokenizer } from './engine/tokenizer.ts'

export type Backend = 'webgpu' | 'wasm'

export type WorkerRequest =
  | { type: 'load'; forceWasm?: boolean; wasmDecoder?: boolean; modelBase?: string }
  | { type: 'transcribe'; id: number; audio: Float32Array }
  | { type: 'cancel'; id: number }

export type WorkerResponse =
  | { type: 'progress'; progress: LoadProgress }
  | { type: 'compiling' }
  | { type: 'ready'; backend: Backend; decoderBackend: Backend; fromCache: boolean; loadMs: number }
  | { type: 'load-error'; message: string; offline: boolean }
  | { type: 'plan'; id: number; ranges: Array<[number, number]>; samples: number }
  | { type: 'window-start'; id: number; index: number }
  | { type: 'window-done'; id: number; index: number; segment: Segment | null; ms: number }
  | { type: 'done'; id: number; segments: Segment[]; ms: number }
  | { type: 'cancelled'; id: number }
  | { type: 'error'; id: number; message: string }

declare const self: DedicatedWorkerGlobalScope
const post = (m: WorkerResponse) => self.postMessage(m)

const BASE = import.meta.env.BASE_URL
const ORT_VERSION = __ORT_VERSION__

let model: Transcriber | null = null
let loading: Promise<void> | null = null
const cancelled = new Set<number>()

async function webgpuUsable(): Promise<boolean> {
  try {
    const gpu = (navigator as Navigator & { gpu?: GPU }).gpu
    if (!gpu) return false
    const adapter = await gpu.requestAdapter()
    return !!adapter && adapter.features.has('shader-f16')
  } catch {
    return false
  }
}

async function importOrt(backend: Backend): Promise<typeof Ort> {
  const ort = backend === 'webgpu' ? await import('onnxruntime-web/webgpu') : await import('onnxruntime-web/wasm')
  ort.env.wasm.wasmPaths = `${BASE}ort/${ORT_VERSION}/`
  // GitHub Pages cannot send COOP/COEP, so SharedArrayBuffer is unavailable and
  // the runtime is single-threaded. Saying so avoids a warning and a probe.
  ort.env.wasm.numThreads = 1
  ort.env.logLevel = 'error'
  return ort
}

function finite(t: Ort.Tensor): boolean {
  const d = t.data as Float32Array
  for (let i = 0; i < d.length; i += 97) if (!Number.isFinite(d[i])) return false
  return true
}

/** Runs one encoder pass and a few decoder steps on silence; throws if anything is off. */
async function selfTest(ort: typeof Ort, enc: Ort.InferenceSession, dec: Ort.InferenceSession): Promise<void> {
  const feats = new Float32Array(80 * 3000).fill(-0.5)
  const o = await enc.run({ input_features: new ort.Tensor('float32', feats, [1, 80, 3000]) })
  const hidden = o.last_hidden_state
  if (hidden.location === 'cpu' && !finite(hidden)) throw new Error('encoder produced NaN')
  const empty = new ort.Tensor('float32', new Float32Array(0), [1, 8, 0, 64])
  const feed: Record<string, Ort.Tensor> = {
    encoder_hidden_states: hidden,
    use_cache_branch: new ort.Tensor('bool', new Uint8Array([0]), [1]),
    input_ids: new ort.Tensor('int64', BigInt64Array.from([1n]), [1, 1]),
  }
  for (const n of dec.inputNames) if (n.startsWith('past_key_values.')) feed[n] = empty
  const r = await dec.run(feed)
  const logits = r.logits
  const data = (await logits.getData()) as Float32Array
  for (const [k, t] of Object.entries(r)) if (k !== 'logits' && t.location === 'gpu-buffer') t.dispose()
  if (!data.length || !finite(new ort.Tensor('float32', data, [data.length]))) throw new Error('decoder produced NaN')
}

async function createSessions(ort: typeof Ort, backend: Backend, enc: Uint8Array, dec: Uint8Array, wasmDecoder = false) {
  if (backend === 'webgpu') {
    const encoder = await ort.InferenceSession.create(enc, { executionProviders: ['webgpu'], graphOptimizationLevel: 'all', logSeverityLevel: 3 })
    let decoder: Ort.InferenceSession
    let decoderBackend: Backend = 'webgpu'
    try {
      if (wasmDecoder) throw new Error('WASM decoder requested')
      // Keep the KV cache on the GPU between steps; logits are read back with getData().
      decoder = await ort.InferenceSession.create(dec, {
        executionProviders: ['webgpu'],
        graphOptimizationLevel: 'all',
        logSeverityLevel: 3,
        preferredOutputLocation: 'gpu-buffer',
      })
      await selfTest(ort, encoder, decoder)
    } catch (e) {
      console.warn('[ozen] WebGPU decoder unavailable, using WASM for the decoder', e)
      decoderBackend = 'wasm'
      decoder = await ort.InferenceSession.create(dec, { executionProviders: ['wasm'], logSeverityLevel: 3 })
      await selfTest(ort, encoder, decoder)
    }
    return { encoder, decoder, decoderBackend }
  }
  const encoder = await ort.InferenceSession.create(enc, { executionProviders: ['wasm'], logSeverityLevel: 3 })
  const decoder = await ort.InferenceSession.create(dec, { executionProviders: ['wasm'], logSeverityLevel: 3 })
  return { encoder, decoder, decoderBackend: 'wasm' as Backend }
}

async function load(forceWasm = false, wasmDecoder = false, modelBase?: string): Promise<void> {
  const t0 = performance.now()
  let fromCache = true
  let files
  try {
    files = await loadModelFiles(
      (progress) => {
        fromCache = progress.fromCache
        post({ type: 'progress', progress })
      },
      { baseUrl: modelBase },
    )
  } catch (e) {
    const offline = e instanceof ModelDownloadError ? e.offline : false
    post({ type: 'load-error', message: (e as Error).message, offline })
    throw e
  }
  post({ type: 'compiling' })
  const filtersRes = await fetch(`${BASE}mel_filters.bin`)
  if (!filtersRes.ok) throw new Error('mel_filters.bin missing')
  const filters = parseMelFilters(await filtersRes.arrayBuffer())
  const tokenizer = new Tokenizer(new TextDecoder().decode(files.tokenizer))

  let backend: Backend = !forceWasm && (await webgpuUsable()) ? 'webgpu' : 'wasm'
  let sessions
  let ort: typeof Ort
  try {
    ort = await importOrt(backend)
    sessions = await createSessions(ort, backend, files.encoder, files.decoder, wasmDecoder)
  } catch (e) {
    if (backend !== 'webgpu') {
      // A cached file that will not load is most likely corrupt; forget it.
      await clearModelCache()
      post({ type: 'load-error', message: (e as Error).message, offline: false })
      throw e
    }
    console.warn('[ozen] WebGPU failed, falling back to WASM', e)
    backend = 'wasm'
    ort = await importOrt('wasm')
    sessions = await createSessions(ort, 'wasm', files.encoder, files.decoder)
  }
  model = new Transcriber(ort, sessions.encoder, sessions.decoder, tokenizer, filters)
  const loadMs = performance.now() - t0
  console.info(`[ozen] model ready on ${backend} (decoder ${sessions.decoderBackend}) in ${Math.round(loadMs)} ms${fromCache ? ' from cache' : ''}`)
  post({ type: 'ready', backend, decoderBackend: sessions.decoderBackend, fromCache, loadMs })
}

function ensureLoaded(forceWasm = false, wasmDecoder = false, modelBase?: string): Promise<void> {
  loading ??= load(forceWasm, wasmDecoder, modelBase).catch((e) => {
    loading = null
    throw e
  })
  return loading
}

async function transcribe(id: number, audio: Float32Array) {
  try {
    if (!model) await ensureLoaded()
    const m = model
    if (!m) throw new Error('model not loaded')
    const t0 = performance.now()
    let tw = t0
    const segments = await m.transcribe(audio, {
      onPlan: (ranges) => post({ type: 'plan', id, ranges, samples: audio.length }),
      onWindowStart: (index) => {
        tw = performance.now()
        post({ type: 'window-start', id, index })
      },
      onWindowDone: (index, _r, segment) => post({ type: 'window-done', id, index, segment, ms: performance.now() - tw }),
      shouldStop: () => cancelled.has(id),
    })
    const ms = performance.now() - t0
    console.info(`[ozen] transcribed ${(audio.length / 16000).toFixed(1)} s of audio in ${(ms / 1000).toFixed(2)} s`)
    post({ type: 'done', id, segments, ms })
  } catch (e) {
    if (e instanceof AbortedError) post({ type: 'cancelled', id })
    else post({ type: 'error', id, message: (e as Error)?.message ?? String(e) })
  } finally {
    cancelled.delete(id)
  }
}

self.addEventListener('message', (event: MessageEvent<WorkerRequest>) => {
  const msg = event.data
  if (msg.type === 'load') {
    ensureLoaded(msg.forceWasm, msg.wasmDecoder, msg.modelBase).catch((e) => console.error('[ozen] model load failed', e))
  } else if (msg.type === 'transcribe') {
    void transcribe(msg.id, msg.audio)
  } else if (msg.type === 'cancel') {
    cancelled.add(msg.id)
  }
})

export const MODEL_TOTAL_BYTES = MODEL_FILES.reduce((a, f) => a + f.bytes, 0)
