/**
 * The on-device transcriber: segmenter -> log-mel -> ONNX encoder -> greedy
 * merged-decoder loop -> byte-level BPE. Mirrors reference.Model exactly.
 *
 * DOM-free and runtime-agnostic: the ONNX Runtime module (onnxruntime-web in
 * the browser worker, onnxruntime-node in the golden test) and its sessions are
 * injected, so the browser and the Node harness run the same code.
 */

import type { InferenceSession, Tensor } from 'onnxruntime-common'
import { BOS, EOS, MAX_NEW_TOKENS } from './constants.ts'
import { isDegenerate } from './degenerate.ts'
import { LogMel } from './mel.ts'
import { segment } from './segmenter.ts'
import type { Tokenizer } from './tokenizer.ts'

export interface OrtModule {
  Tensor: typeof Tensor
}

export interface Segment {
  /** First sample (16 kHz) of the paragraph. */
  start: number
  /** One past the last sample. */
  end: number
  text: string
}

export interface TranscribeHooks {
  /** Called once with every paragraph that will be sent to the model. */
  onPlan?: (ranges: Array<[number, number]>) => void
  /** Called before paragraph `index` is processed. */
  onWindowStart?: (index: number, range: [number, number]) => void
  /** Called after paragraph `index`, with its segment or null when it was empty/dropped. */
  onWindowDone?: (index: number, range: [number, number], segment: Segment | null) => void
  /** Checked between windows and decoder steps. */
  shouldStop?: () => boolean
}

export class AbortedError extends Error {
  constructor() {
    super('aborted')
    this.name = 'AbortError'
  }
}

const HEADS = 8
const HEAD_DIM = 64

export class Transcriber {
  readonly layers: number
  private readonly ort: OrtModule
  private readonly enc: InferenceSession
  private readonly dec: InferenceSession
  private readonly tok: Tokenizer
  private readonly mel: LogMel

  constructor(ort: OrtModule, encoder: InferenceSession, decoder: InferenceSession, tokenizer: Tokenizer, filters: Float32Array) {
    this.ort = ort
    this.enc = encoder
    this.dec = decoder
    this.tok = tokenizer
    this.mel = new LogMel(filters)
    this.layers = decoder.inputNames.filter((n) => n.endsWith('.decoder.key')).length
  }

  logMel(x: ArrayLike<number>): Float32Array {
    return this.mel.compute(x)
  }

  decode(ids: readonly number[]): string {
    return this.tok.decode(ids)
  }

  /** Greedy decode one 30 s window of features ([80][3000]). Returns new token ids (no BOS/EOS). */
  async tokens(features: Float32Array, shouldStop?: () => boolean): Promise<number[]> {
    const T = this.ort.Tensor
    const encOut = await this.enc.run({ input_features: new T('float32', features, [1, 80, 3000]) })
    const hidden = encOut.last_hidden_state ?? Object.values(encOut)[0]

    const empty = () => new T('float32', new Float32Array(0), [1, HEADS, 0, HEAD_DIM])
    const feed: Record<string, Tensor> = {
      encoder_hidden_states: hidden,
      use_cache_branch: new T('bool', new Uint8Array([0]), [1]),
    }
    for (let l = 0; l < this.layers; l++) {
      for (const kind of ['decoder', 'encoder']) {
        for (const kv of ['key', 'value']) feed[`past_key_values.${l}.${kind}.${kv}`] = empty()
      }
    }

    const allOutputs = this.dec.outputNames
    const stepOutputs = allOutputs.filter((n) => n === 'logits' || n.includes('.decoder.'))
    const owned: Tensor[] = [] // GPU-resident tensors we must free
    const free = (t: Tensor | undefined) => {
      if (t && t.location === 'gpu-buffer') t.dispose()
    }

    const ids = [BOS]
    try {
      for (let step = 0; step < MAX_NEW_TOKENS; step++) {
        if (shouldStop?.()) throw new AbortedError()
        feed.input_ids = new T('int64', BigInt64Array.from([BigInt(ids[ids.length - 1])]), [1, 1])
        const res = await this.dec.run(feed, step === 0 ? allOutputs : stepOutputs)
        const logits = res.logits
        const data = (await logits.getData()) as Float32Array
        const vocab = logits.dims[logits.dims.length - 1]
        const base = data.length - vocab
        // argmax over the full vocabulary, first index on ties (numpy).
        let best = 0
        let bestV = data[base]
        for (let i = 1; i < vocab; i++) {
          const v = data[base + i]
          if (v > bestV) {
            bestV = v
            best = i
          }
        }
        free(logits)
        if (best === EOS) {
          for (const [name, t] of Object.entries(res)) if (name !== 'logits') free(t)
          break
        }
        ids.push(best)
        for (let l = 0; l < this.layers; l++) {
          for (const kv of ['key', 'value']) {
            const dk = `past_key_values.${l}.decoder.${kv}`
            if (step > 0) free(feed[dk])
            feed[dk] = res[`present.${l}.decoder.${kv}`]
            if (step === 0) {
              const ek = `past_key_values.${l}.encoder.${kv}`
              feed[ek] = res[`present.${l}.encoder.${kv}`]
              owned.push(feed[ek])
            }
          }
        }
        feed.use_cache_branch = new T('bool', new Uint8Array([1]), [1])
      }
    } finally {
      if (ids.length > 1) {
        for (let l = 0; l < this.layers; l++) for (const kv of ['key', 'value']) free(feed[`past_key_values.${l}.decoder.${kv}`])
      }
      for (const t of owned) free(t)
      free(hidden)
    }
    return ids.slice(1)
  }

  async transcribeWindow(x: ArrayLike<number>, shouldStop?: () => boolean): Promise<string> {
    return this.tok.decode(await this.tokens(this.mel.compute(x), shouldStop))
  }

  async transcribe(x: Float32Array, hooks: TranscribeHooks = {}): Promise<Segment[]> {
    const ranges = segment(x)
    hooks.onPlan?.(ranges)
    const out: Segment[] = []
    for (let i = 0; i < ranges.length; i++) {
      if (hooks.shouldStop?.()) throw new AbortedError()
      const range = ranges[i]
      hooks.onWindowStart?.(i, range)
      const text = await this.transcribeWindow(x.subarray(range[0], range[1]), hooks.shouldStop)
      let seg: Segment | null = null
      if (text && !isDegenerate(text)) {
        seg = { start: range[0], end: range[1], text }
        out.push(seg)
      }
      hooks.onWindowDone?.(i, range, seg)
    }
    return out
  }
}
