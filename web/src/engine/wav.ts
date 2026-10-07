/** Minimal RIFF/WAVE reader for 16-bit PCM and 32-bit float files (tests, Node harness, fast path in the browser). */

export interface Wav {
  sampleRate: number
  channels: number
  /** Mono mix as float32 in [-1, 1). */
  samples: Float32Array
}

export function parseWav(input: ArrayBuffer | Uint8Array): Wav {
  const bytes = input instanceof Uint8Array ? input : new Uint8Array(input)
  const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const tag = (o: number) => String.fromCharCode(bytes[o], bytes[o + 1], bytes[o + 2], bytes[o + 3])
  if (bytes.byteLength < 12 || tag(0) !== 'RIFF' || tag(8) !== 'WAVE') throw new Error('not a WAVE file')
  let off = 12
  let format = 0
  let channels = 0
  let sampleRate = 0
  let bits = 0
  let data: { off: number; len: number } | null = null
  while (off + 8 <= bytes.byteLength) {
    const id = tag(off)
    const size = v.getUint32(off + 4, true)
    const body = off + 8
    if (id === 'fmt ') {
      format = v.getUint16(body, true)
      channels = v.getUint16(body + 2, true)
      sampleRate = v.getUint32(body + 4, true)
      bits = v.getUint16(body + 14, true)
      if (format === 0xfffe && size >= 26) format = v.getUint16(body + 24, true)
    } else if (id === 'data') {
      data = { off: body, len: Math.min(size, bytes.byteLength - body) }
      break
    }
    off = body + size + (size & 1)
  }
  if (!data || !channels) throw new Error('WAVE file has no fmt/data chunk')
  const frameBytes = (bits / 8) * channels
  const frames = Math.floor(data.len / frameBytes)
  const out = new Float32Array(frames)
  for (let i = 0; i < frames; i++) {
    let s = 0
    for (let c = 0; c < channels; c++) {
      const p = data.off + i * frameBytes + c * (bits / 8)
      if (format === 1 && bits === 16) s += v.getInt16(p, true) / 32768
      else if (format === 3 && bits === 32) s += v.getFloat32(p, true)
      else if (format === 1 && bits === 24) s += (((bytes[p] | (bytes[p + 1] << 8) | (bytes[p + 2] << 16)) << 8) >> 8) / 8388608
      else if (format === 1 && bits === 32) s += v.getInt32(p, true) / 2147483648
      else if (format === 1 && bits === 8) s += (bytes[p] - 128) / 128
      else throw new Error(`unsupported WAVE encoding (format ${format}, ${bits} bit)`)
    }
    out[i] = channels === 1 ? s : s / channels
  }
  return { sampleRate, channels, samples: out }
}
