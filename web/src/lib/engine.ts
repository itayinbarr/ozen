/**
 * Main-thread handle on the engine worker: model loading state plus a
 * promise-based transcribe() that streams paragraphs as they finish.
 */

import type { Segment } from '../engine/model.ts'
import type { Backend, WorkerRequest, WorkerResponse } from '../worker.ts'

export type { Segment }

export interface ModelState {
  phase: 'idle' | 'loading' | 'compiling' | 'ready' | 'error'
  loaded: number
  total: number
  fromCache: boolean
  backend?: Backend
  decoderBackend?: Backend
  error?: string
  offline?: boolean
}

export interface TranscribeHandlers {
  onPlan?: (ranges: Array<[number, number]>, samples: number) => void
  onWindowStart?: (index: number) => void
  onWindowDone?: (index: number, segment: Segment | null, ms: number) => void
}

export interface Job {
  id: number
  done: Promise<{ segments: Segment[]; ms: number }>
  cancel: () => void
}

export class CancelledError extends Error {
  constructor() {
    super('cancelled')
    this.name = 'CancelledError'
  }
}

type Listener = (s: ModelState) => void

/**
 * Crash-loop guard. A GPU driver fault can take the whole tab down while the
 * WebGPU sessions are being created, before any error reaches us. We mark the
 * attempt in localStorage and clear it once the model is ready; if a load finds
 * the mark still there, the previous one never finished, so WASM is used for a day.
 */
const gpuGuard = {
  PENDING: 'ozen-gpu-pending',
  SKIP: 'ozen-gpu-skip-until',
  shouldSkip(): boolean {
    try {
      const ls = window.localStorage
      if (ls.getItem(this.PENDING)) {
        ls.removeItem(this.PENDING)
        ls.setItem(this.SKIP, String(Date.now() + 24 * 3600 * 1000))
        return true
      }
      return Number(ls.getItem(this.SKIP) ?? 0) > Date.now()
    } catch {
      return false
    }
  },
  begin() {
    try {
      window.localStorage.setItem(this.PENDING, String(Date.now()))
    } catch {
      /* storage unavailable */
    }
  },
  end() {
    try {
      window.localStorage.removeItem(this.PENDING)
    } catch {
      /* storage unavailable */
    }
  },
}

export class EngineClient {
  private worker: Worker
  private listeners = new Set<Listener>()
  private jobs = new Map<number, { handlers: TranscribeHandlers; resolve: (v: { segments: Segment[]; ms: number }) => void; reject: (e: Error) => void }>()
  private nextId = 1
  state: ModelState = { phase: 'idle', loaded: 0, total: 0, fromCache: true }

  constructor() {
    this.worker = new Worker(new URL('../worker.ts', import.meta.url), { type: 'module', name: 'ozen-engine' })
    this.worker.addEventListener('message', (e: MessageEvent<WorkerResponse>) => this.onMessage(e.data))
    this.worker.addEventListener('error', (e) => {
      this.set({ phase: 'error', error: e.message || 'worker failed' })
      for (const j of this.jobs.values()) j.reject(new Error(e.message || 'worker failed'))
      this.jobs.clear()
    })
  }

  /** Stops the worker (frees the GPU device and wasm heap). */
  dispose(): void {
    this.worker.terminate()
  }

  subscribe(fn: Listener): () => void {
    this.listeners.add(fn)
    fn(this.state)
    return () => this.listeners.delete(fn)
  }

  private set(patch: Partial<ModelState>) {
    this.state = { ...this.state, ...patch }
    for (const fn of this.listeners) fn(this.state)
  }

  /**
   * Diagnostics/test switches: `?backend=wasm` forces the CPU path, `?decoder=wasm`
   * only the decoder, `?modelBase=<url>` downloads from a mirror (still SHA-256 pinned).
   */
  load(): void {
    if (this.state.phase === 'loading' || this.state.phase === 'compiling' || this.state.phase === 'ready') return
    const q = typeof location !== 'undefined' ? new URLSearchParams(location.search) : new URLSearchParams()
    this.set({ phase: 'loading', error: undefined, offline: undefined })
    const forceWasm = q.get('backend') === 'wasm' || gpuGuard.shouldSkip()
    if (!forceWasm) gpuGuard.begin()
    this.post({
      type: 'load',
      forceWasm,
      wasmDecoder: q.get('decoder') === 'wasm',
      modelBase: q.get('modelBase') ?? undefined,
    })
  }

  transcribe(audio: Float32Array, handlers: TranscribeHandlers = {}): Job {
    const id = this.nextId++
    if (this.state.phase === 'idle' || this.state.phase === 'error') this.load()
    const done = new Promise<{ segments: Segment[]; ms: number }>((resolve, reject) => {
      this.jobs.set(id, { handlers, resolve, reject })
    })
    this.post({ type: 'transcribe', id, audio }, [audio.buffer])
    return { id, done, cancel: () => this.post({ type: 'cancel', id }) }
  }

  private post(m: WorkerRequest, transfer: Transferable[] = []) {
    this.worker.postMessage(m, transfer)
  }

  private onMessage(m: WorkerResponse) {
    switch (m.type) {
      case 'progress':
        this.set({
          phase: this.state.phase === 'ready' ? 'ready' : 'loading',
          loaded: m.progress.loaded,
          total: m.progress.total,
          fromCache: m.progress.fromCache,
        })
        break
      case 'compiling':
        this.set({ phase: 'compiling' })
        break
      case 'ready':
        gpuGuard.end()
        this.set({ phase: 'ready', backend: m.backend, decoderBackend: m.decoderBackend, fromCache: m.fromCache })
        break
      case 'load-error':
        gpuGuard.end()
        this.set({ phase: 'error', error: m.message, offline: m.offline })
        for (const j of this.jobs.values()) j.reject(new Error(m.message))
        this.jobs.clear()
        break
      case 'plan':
        this.jobs.get(m.id)?.handlers.onPlan?.(m.ranges, m.samples)
        break
      case 'window-start':
        this.jobs.get(m.id)?.handlers.onWindowStart?.(m.index)
        break
      case 'window-done':
        this.jobs.get(m.id)?.handlers.onWindowDone?.(m.index, m.segment, m.ms)
        break
      case 'done': {
        const j = this.jobs.get(m.id)
        this.jobs.delete(m.id)
        j?.resolve({ segments: m.segments, ms: m.ms })
        break
      }
      case 'cancelled': {
        const j = this.jobs.get(m.id)
        this.jobs.delete(m.id)
        j?.reject(new CancelledError())
        break
      }
      case 'error': {
        const j = this.jobs.get(m.id)
        this.jobs.delete(m.id)
        j?.reject(new Error(m.message))
        break
      }
    }
  }
}
