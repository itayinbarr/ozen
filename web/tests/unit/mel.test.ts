import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { FFT } from '../../src/engine/fft.ts'
import { LogMel, parseMelFilters } from '../../src/engine/mel.ts'
import { parseWav } from '../../src/engine/wav.ts'
import { SPEC } from './paths.ts'

describe('FFT', () => {
  for (const n of [400, 16, 15, 20]) {
    it(`matches a naive DFT for n=${n}`, () => {
      const fft = new FFT(n)
      const re = new Float64Array(n).map((_, i) => Math.sin(i * 0.37) + 0.3 * Math.cos(i * 1.9) + (i % 7) * 0.01)
      const im = new Float64Array(n).map((_, i) => (i % 3) * 0.05)
      const or = new Float64Array(n)
      const oi = new Float64Array(n)
      fft.transform(re, im, or, oi)
      let maxErr = 0
      for (let k = 0; k < n; k++) {
        let sr = 0
        let si = 0
        for (let t = 0; t < n; t++) {
          const a = (-2 * Math.PI * k * t) / n
          sr += re[t] * Math.cos(a) - im[t] * Math.sin(a)
          si += re[t] * Math.sin(a) + im[t] * Math.cos(a)
        }
        maxErr = Math.max(maxErr, Math.abs(sr - or[k]), Math.abs(si - oi[k]))
      }
      expect(maxErr).toBeLessThan(1e-9)
    })
  }
})

describe('log-mel', () => {
  it('matches spec/golden/sample-he.mel.bin (80x3000, max abs diff < 2e-3)', () => {
    const filters = parseMelFilters(readFileSync(join(SPEC, 'mel_filters.bin')))
    const x = parseWav(readFileSync(join(SPEC, 'golden/sample-he.wav'))).samples
    const mel = new LogMel(filters).compute(x)
    const buf = readFileSync(join(SPEC, 'golden/sample-he.mel.bin'))
    const ref = new Float32Array(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength))
    expect(mel.length).toBe(80 * 3000)
    expect(ref.length).toBe(80 * 3000)
    let maxDiff = 0
    for (let i = 0; i < ref.length; i++) maxDiff = Math.max(maxDiff, Math.abs(ref[i] - mel[i]))
    expect(maxDiff).toBeLessThan(2e-3)
    // In practice the float64 pipeline is far tighter than the tolerance.
    expect(maxDiff).toBeLessThan(1e-4)
  })

  it('handles silence and inputs longer than 30 s', () => {
    const filters = parseMelFilters(readFileSync(join(SPEC, 'mel_filters.bin')))
    const m = new LogMel(filters)
    const silent = m.compute(new Float32Array(1000))
    expect(silent.every((v) => Number.isFinite(v))).toBe(true)
    const long = m.compute(new Float32Array(40 * 16000).map((_, i) => Math.sin(i / 10) * 0.1))
    expect(long.length).toBe(80 * 3000)
  })
})
