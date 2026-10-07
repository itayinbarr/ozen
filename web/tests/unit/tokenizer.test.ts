import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { byteDecoder, Tokenizer } from '../../src/engine/tokenizer.ts'
import { MODEL_DIR } from './paths.ts'

/** GPT-2 bytes_to_unicode, forward direction, to build test tokens. */
function byteEncoder(): Map<number, string> {
  const m = new Map<number, string>()
  for (const [cp, b] of byteDecoder()) m.set(b, String.fromCodePoint(cp))
  return m
}

function toTokenString(s: string): string {
  const enc = byteEncoder()
  return Array.from(new TextEncoder().encode(s), (b) => enc.get(b)!).join('')
}

describe('byte decoder', () => {
  it('is a bijection over all 256 bytes', () => {
    const bd = byteDecoder()
    expect(bd.size).toBe(256)
    expect(new Set(bd.values()).size).toBe(256)
    expect(bd.get('!'.codePointAt(0)!)).toBe(0x21)
    expect(bd.get(0x100)).toBe(0) // first remapped byte
    expect(bd.get('Ġ'.codePointAt(0)!)).toBe(0x20) // space
  })
})

describe('Tokenizer (synthetic vocab)', () => {
  const vocab: Record<string, number> = {
    '<unk>': 0,
    '<s>': 1,
    '</s>': 2,
    [toTokenString('של')]: 3,
    [toTokenString('ום')]: 4,
    [toTokenString(' עולם')]: 5,
    [toTokenString('.')]: 6,
    [toTokenString('  ')]: 7,
  }
  // Split one multi-byte letter across two tokens to prove bytes are joined before UTF-8 decoding.
  const alef = new TextEncoder().encode('א')
  const enc = byteEncoder()
  vocab[enc.get(alef[0])!] = 8
  vocab[enc.get(alef[1])!] = 9
  const tok = new Tokenizer({
    model: { vocab },
    added_tokens: [
      { id: 0, content: '<unk>' },
      { id: 1, content: '<s>' },
      { id: 2, content: '</s>' },
    ],
  })

  it('round-trips Hebrew and skips special ids', () => {
    expect(tok.decode([1, 3, 4, 5, 6, 2])).toBe('שלום עולם.')
  })
  it('joins bytes split across tokens', () => {
    expect(tok.decode([8, 9])).toBe('א')
  })
  it('collapses and trims whitespace', () => {
    expect(tok.decode([7, 3, 4, 7, 7, 5, 7])).toBe('שלום עולם')
  })
})

const real = join(MODEL_DIR, 'tokenizer.json')
describe.skipIf(!existsSync(real))('Tokenizer (model tokenizer.json)', () => {
  const json = JSON.parse(readFileSync(real, 'utf8'))
  const tok = new Tokenizer(json)
  const vocab: Record<string, number> = json.model.vocab
  it('has the full 8192-token vocabulary', () => {
    expect(tok.size).toBe(8192)
  })
  it('round-trips a Hebrew sentence built from vocab pieces', () => {
    // Greedy longest-match over the vocab is enough to build valid ids.
    const text = ' שלום וברוכים הבאים'
    const target = toTokenString(text)
    const ids: number[] = []
    let i = 0
    while (i < target.length) {
      let j = target.length
      while (j > i && vocab[target.slice(i, j)] === undefined) j--
      expect(j).toBeGreaterThan(i)
      ids.push(vocab[target.slice(i, j)])
      i = j
    }
    expect(tok.decode([1, ...ids, 2])).toBe(text.trim())
  })
  it('decodes id 8191 as ordinary text (never treated as special)', () => {
    expect(tok.decode([8191]).length).toBeGreaterThan(0)
  })
})
