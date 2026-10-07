/**
 * Deterministic synthetic "speech" for the segmenter vectors. Mirrors
 * tools/model/golden.py `lcg_noise` / `synth` bit for bit (uint32 LCG, float64
 * accumulation, float32 result).
 */

import { SR } from './constants.ts'

export interface Piece {
  n: number
  tone?: number
  hz?: number
}

export function lcgNoise(n: number, amp: number, seed: number): Float64Array {
  const out = new Float64Array(n)
  let s = seed >>> 0
  for (let i = 0; i < n; i++) {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0
    out[i] = (s / 4294967296.0 * 2.0 - 1.0) * amp
  }
  return out
}

export function synth(pieces: Piece[], seed: number, noiseAmp = 0.002, envelopeHz = 4.0): Float32Array {
  const total = pieces.reduce((a, p) => a + p.n, 0)
  const x = lcgNoise(total, noiseAmp, seed)
  let off = 0
  // Same association order as numpy: scalar prefix first, then * t, then / SR.
  const envK = 2 * Math.PI * envelopeHz
  for (const p of pieces) {
    if (p.tone) {
      const toneK = 2 * Math.PI * (p.hz ?? 0)
      for (let t = 0; t < p.n; t++) {
        const env = 0.6 + 0.4 * Math.sin((envK * t) / SR)
        x[off + t] += p.tone * env * Math.sin((toneK * t) / SR)
      }
    }
    off += p.n
  }
  return Float32Array.from(x)
}
