/**
 * Whisper log-mel features, mirroring reference.log_mel (HF's numpy path):
 * pad/trim to 30 s, reflect-pad 200, periodic Hann(400), hop 160, |rfft|^2,
 * drop the last frame (3000 left), slaney mel (201x80), log10, clamp to
 * max-8, (x+4)/4. Output layout [80][3000] float32.
 */

import { FFT } from './fft.ts'
import { HOP, N_FFT, N_FRAMES, N_FREQ, N_MELS, N_SAMPLES } from './constants.ts'

/** Parses spec/mel_filters.bin: 201x80 float32 little-endian, row-major [freq][mel]. */
export function parseMelFilters(buf: ArrayBuffer | Uint8Array): Float32Array {
  const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf)
  if (bytes.byteLength !== N_FREQ * N_MELS * 4) {
    throw new Error(`mel_filters.bin: expected ${N_FREQ * N_MELS * 4} bytes, got ${bytes.byteLength}`)
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const out = new Float32Array(N_FREQ * N_MELS)
  for (let i = 0; i < out.length; i++) out[i] = view.getFloat32(i * 4, true)
  return out
}

interface SparseFilter {
  lo: number
  w: Float64Array
}

export class LogMel {
  private readonly fft = new FFT(N_FFT)
  private readonly window = new Float64Array(N_FFT)
  private readonly mels: SparseFilter[] = []
  private readonly fr = new Float64Array(N_FFT)
  private readonly fi = new Float64Array(N_FFT)
  private readonly or = new Float64Array(N_FFT)
  private readonly oi = new Float64Array(N_FFT)
  private readonly padded = new Float64Array(N_SAMPLES + N_FFT)
  private readonly power = new Float64Array(N_FREQ)

  constructor(filters: Float32Array) {
    // np.hanning(N+1)[:-1]: 0.5 - 0.5*cos(2*pi*n/N)
    for (let i = 0; i < N_FFT; i++) this.window[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / N_FFT)
    // Each mel filter touches a narrow band of bins; keep only that band.
    for (let m = 0; m < N_MELS; m++) {
      let lo = -1
      let hi = -1
      for (let f = 0; f < N_FREQ; f++) {
        if (filters[f * N_MELS + m] !== 0) {
          if (lo < 0) lo = f
          hi = f
        }
      }
      if (lo < 0) {
        this.mels.push({ lo: 0, w: new Float64Array(0) })
        continue
      }
      const w = new Float64Array(hi - lo + 1)
      for (let f = lo; f <= hi; f++) w[f - lo] = filters[f * N_MELS + m]
      this.mels.push({ lo, w })
    }
  }

  compute(x: ArrayLike<number>): Float32Array {
    const P = N_FFT / 2
    const padded = this.padded
    const m = Math.min(x.length, N_SAMPLES)
    // audio = zeros(480000); audio[:m] = x[:m]; then reflect-pad by 200.
    padded.fill(0)
    for (let i = 0; i < m; i++) padded[P + i] = x[i]
    for (let i = 0; i < P; i++) {
      padded[i] = padded[2 * P - i] // audio[P - i]
      padded[P + N_SAMPLES + i] = padded[P + N_SAMPLES - 2 - i] // audio[N-2-i]
    }

    const logs = new Float64Array(N_MELS * N_FRAMES)
    let globalMax = -Infinity
    const { fr, fi, or, oi, power, window } = this
    for (let t = 0; t < N_FRAMES; t++) {
      const base = t * HOP
      for (let i = 0; i < N_FFT; i++) {
        fr[i] = padded[base + i] * window[i]
        fi[i] = 0
      }
      this.fft.transform(fr, fi, or, oi)
      for (let k = 0; k < N_FREQ; k++) power[k] = or[k] * or[k] + oi[k] * oi[k]
      for (let mm = 0; mm < N_MELS; mm++) {
        const { lo, w } = this.mels[mm]
        let s = 0
        for (let j = 0; j < w.length; j++) s += power[lo + j] * w[j]
        const v = Math.log10(Math.max(s, 1e-10))
        logs[mm * N_FRAMES + t] = v
        if (v > globalMax) globalMax = v
      }
    }
    const floor = globalMax - 8.0
    const out = new Float32Array(N_MELS * N_FRAMES)
    for (let i = 0; i < out.length; i++) out[i] = (Math.max(logs[i], floor) + 4.0) / 4.0
    return out
  }
}
