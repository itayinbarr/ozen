/**
 * Decoder for the model's byte-level BPE tokenizer (tokenizer.json). Only
 * decoding is needed on device: special ids are skipped, every token's
 * characters are mapped back to bytes through the inverse of GPT-2's
 * bytes_to_unicode table, the bytes are read as UTF-8 and whitespace is
 * collapsed.
 */

interface TokenizerJson {
  model: { vocab: Record<string, number> }
  added_tokens?: Array<{ id: number; content: string }>
}

/** Inverse of GPT-2's bytes_to_unicode: unicode code point -> byte. */
export function byteDecoder(): Map<number, number> {
  const bs: number[] = []
  for (let b = 0x21; b <= 0x7e; b++) bs.push(b)
  for (let b = 0xa1; b <= 0xac; b++) bs.push(b)
  for (let b = 0xae; b <= 0xff; b++) bs.push(b)
  const cs = bs.slice()
  let n = 0
  for (let b = 0; b < 256; b++) {
    if (!bs.includes(b)) {
      bs.push(b)
      cs.push(256 + n)
      n++
    }
  }
  const map = new Map<number, number>()
  bs.forEach((b, i) => map.set(cs[i], b))
  return map
}

export class Tokenizer {
  private readonly tokens: Array<Uint8Array | undefined> = []
  private readonly special = new Set<number>()
  private readonly utf8 = new TextDecoder('utf-8', { fatal: false })

  constructor(json: TokenizerJson | string) {
    const t: TokenizerJson = typeof json === 'string' ? JSON.parse(json) : json
    const bd = byteDecoder()
    for (const [tok, id] of Object.entries(t.model.vocab)) {
      const bytes: number[] = []
      for (const ch of tok) {
        const b = bd.get(ch.codePointAt(0)!)
        if (b !== undefined) bytes.push(b)
      }
      this.tokens[id] = Uint8Array.from(bytes)
    }
    for (const a of t.added_tokens ?? []) this.special.add(a.id)
  }

  get size(): number {
    return this.tokens.length
  }

  decode(ids: readonly number[]): string {
    const parts: Uint8Array[] = []
    let len = 0
    for (const id of ids) {
      if (this.special.has(id)) continue
      const b = this.tokens[id]
      if (!b) continue
      parts.push(b)
      len += b.length
    }
    const all = new Uint8Array(len)
    let off = 0
    for (const p of parts) {
      all.set(p, off)
      off += p.length
    }
    return this.utf8.decode(all).split(/\s+/).filter(Boolean).join(' ')
  }
}
