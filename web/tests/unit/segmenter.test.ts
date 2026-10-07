import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { segment } from '../../src/engine/segmenter.ts'
import { lcgNoise, synth, type Piece } from '../../src/engine/synth.ts'
import { parseWav } from '../../src/engine/wav.ts'
import { SPEC } from './paths.ts'

interface Vectors {
  noiseAmp: number
  envelopeHz: number
  cases: Array<{ name: string; seed: number; pieces: Piece[]; samples: number; expected: Array<[number, number]> }>
}

const vectors: Vectors = JSON.parse(readFileSync(join(SPEC, 'segmenter-vectors.json'), 'utf8'))

describe('segmenter vectors (spec/segmenter-vectors.json)', () => {
  for (const c of vectors.cases) {
    it(c.name, () => {
      const x = synth(c.pieces, c.seed, vectors.noiseAmp, vectors.envelopeHz)
      expect(x.length).toBe(c.samples)
      expect(segment(x)).toEqual(c.expected)
    })
  }
})

describe('segmenter on golden audio', () => {
  it('matches the reference cut points for long-he.wav and sample-he.wav', () => {
    const golden = JSON.parse(readFileSync(join(SPEC, 'golden/golden.json'), 'utf8'))
    for (const name of ['sample-he.wav', 'long-he.wav']) {
      const x = parseWav(readFileSync(join(SPEC, 'golden', name))).samples
      const got = segment(x)
      // Golden segments only include paragraphs that produced text, so every one must be a cut point.
      for (const s of golden[name].segments) expect(got).toContainEqual([s.start, s.end])
    }
  })
})

describe('lcg noise', () => {
  it('uses uint32 wrap-around arithmetic', () => {
    const n = lcgNoise(3, 1, 0)
    // s1 = 1013904223, s2 = (1013904223*1664525 + 1013904223) mod 2^32 = 1196435762
    expect(n[0]).toBeCloseTo((1013904223 / 4294967296) * 2 - 1, 15)
    expect(n[1]).toBeCloseTo((1196435762 / 4294967296) * 2 - 1, 15)
  })
})
