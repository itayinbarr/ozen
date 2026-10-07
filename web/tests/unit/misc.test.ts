import { describe, expect, it } from 'vitest'
import { cer } from '../../src/lib/cer.ts'
import { toMarkdown, toText } from '../../src/lib/exporters.ts'
import { fmt, remainingLabel, safeFileName, stem } from '../../src/lib/format.ts'
import { lengthBucket } from '../../src/lib/analytics.ts'
import { parseWav } from '../../src/engine/wav.ts'

describe('format', () => {
  it('formats like the design', () => {
    expect(fmt(0)).toBe('0:00')
    expect(fmt(74)).toBe('1:14')
    expect(fmt(3725)).toBe('1:02:05')
  })
  it('remaining time in Hebrew', () => {
    expect(remainingLabel(12.4)).toBe('עוד כ־12 שניות')
    expect(remainingLabel(300)).toBe('עוד כ־5 דקות')
  })
  it('file names', () => {
    expect(stem('PTT-20261008-WA0012.opus')).toBe('PTT-20261008-WA0012')
    expect(safeFileName('פגישה: 2/10')).toBe('פגישה 2 10')
  })
  it('length buckets', () => {
    expect(lengthBucket(30)).toBe('<1m')
    expect(lengthBucket(300)).toBe('1-10m')
    expect(lengthBucket(1200)).toBe('10m+')
  })
})

describe('exporters', () => {
  const doc = { title: 'פגישה', date: 'היום, 09:12', duration: 74, segments: [{ start: 0, text: 'שלום.' }, { start: 9, text: 'מה נשמע?' }] }
  it('text', () => {
    expect(toText(doc)).toBe('פגישה\nהיום, 09:12 · 1:14\n\n[0:00] שלום.\n\n[0:09] מה נשמע?\n')
  })
  it('markdown', () => {
    expect(toMarkdown(doc)).toBe('# פגישה\n\n_היום, 09:12 · 1:14_\n\n**0:00**\nשלום.\n\n**0:09**\nמה נשמע?\n')
  })
})

describe('cer', () => {
  it('counts edits per reference character', () => {
    expect(cer('שלום', 'שלום')).toBe(0)
    expect(cer('שלום', 'שלם')).toBe(0.25)
  })
})

describe('wav', () => {
  it('parses 16-bit PCM with extra chunks', () => {
    const data = new Int16Array([0, 16384, -32768])
    const buf = new Uint8Array(44 + 12 + data.byteLength)
    const v = new DataView(buf.buffer)
    const w = (o: number, s: string) => [...s].forEach((c, i) => (buf[o + i] = c.charCodeAt(0)))
    w(0, 'RIFF'); v.setUint32(4, buf.length - 8, true); w(8, 'WAVE')
    w(12, 'fmt '); v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true)
    v.setUint32(24, 16000, true); v.setUint32(28, 32000, true); v.setUint16(32, 2, true); v.setUint16(34, 16, true)
    w(36, 'LIST'); v.setUint32(40, 4, true); w(44, 'INFO')
    w(48, 'data'); v.setUint32(52, data.byteLength, true)
    buf.set(new Uint8Array(data.buffer), 56)
    const out = parseWav(buf)
    expect(out.sampleRate).toBe(16000)
    expect(Array.from(out.samples)).toEqual([0, 0.5, -1])
  })
})
