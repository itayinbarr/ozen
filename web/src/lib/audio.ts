/**
 * Browser-side audio decoding to 16 kHz mono PCM. Runs on the main thread
 * because AudioContext is not available in workers; the result is transferred
 * to the engine worker.
 *
 * Order: 16-bit/float WAV at 16 kHz is parsed directly (bit-exact with the
 * reference); everything else goes through decodeAudioData on a 16 kHz
 * context (the browser resamples); containers the browser cannot open (e.g.
 * WhatsApp .opus on older Safari) are converted with ffmpeg.wasm, fetched from
 * a CDN only when needed (LGPL, so never bundled).
 */

import { parseWav } from '../engine/wav.ts'

export const SAMPLE_RATE = 16000

export const ACCEPT_ATTRIBUTE =
  'audio/*,video/*,.mp3,.wav,.m4a,.aac,.flac,.ogg,.oga,.opus,.webm,.mp4,.m4b,.mov,.amr,.3gp,.aiff,.aif,.caf,.wma,.mkv'

/** Containers the Web Audio API generally cannot open by itself. */
const NEEDS_TRANSCODE = /\.(mkv|avi|wma|amr|3gp|wmv|flv|ts|mpg|mpeg)$/i

export class AudioDecodeError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options)
    this.name = 'AudioDecodeError'
  }
}

export interface Decoded {
  pcm: Float32Array
  /** A playable version when the original is not playable here (ffmpeg path). */
  playable?: Blob
}

export async function decodeAudio(file: Blob, name = (file as File).name ?? ''): Promise<Decoded> {
  const buffer = await file.arrayBuffer()
  const wav = tryWav(buffer)
  if (wav) return { pcm: wav }
  if (!NEEDS_TRANSCODE.test(name)) {
    try {
      return { pcm: await decodeWithWebAudio(buffer.slice(0)) }
    } catch (error) {
      return transcode(buffer, name, error)
    }
  }
  return transcode(buffer, name)
}

function tryWav(buffer: ArrayBuffer): Float32Array | null {
  try {
    const head = new Uint8Array(buffer, 0, Math.min(12, buffer.byteLength))
    if (String.fromCharCode(...head.subarray(0, 4)) !== 'RIFF') return null
    const w = parseWav(buffer)
    return w.sampleRate === SAMPLE_RATE ? w.samples : null
  } catch {
    return null
  }
}

async function decodeWithWebAudio(buffer: ArrayBuffer): Promise<Float32Array> {
  const Ctx: typeof AudioContext =
    window.AudioContext ?? (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext
  let context: BaseAudioContext
  try {
    context = new Ctx({ sampleRate: SAMPLE_RATE })
  } catch {
    context = new OfflineAudioContext(1, 1, SAMPLE_RATE)
  }
  try {
    const decoded = await context.decodeAudioData(buffer)
    return toMono(decoded)
  } finally {
    if ('close' in context) await (context as AudioContext).close().catch(() => undefined)
  }
}

function toMono(buffer: AudioBuffer): Float32Array {
  // Copy: AudioBuffer storage is not always transferable to the worker.
  if (buffer.numberOfChannels === 1) return buffer.getChannelData(0).slice()
  const out = new Float32Array(buffer.length)
  for (let c = 0; c < buffer.numberOfChannels; c++) {
    const data = buffer.getChannelData(c)
    for (let i = 0; i < out.length; i++) out[i] += data[i]
  }
  for (let i = 0; i < out.length; i++) out[i] /= buffer.numberOfChannels
  return out
}

async function transcode(buffer: ArrayBuffer, name: string, originalError?: unknown): Promise<Decoded> {
  try {
    const wav = await transcodeToWav(buffer, name)
    const pcm = tryWav(wav.slice(0)) ?? (await decodeWithWebAudio(wav.slice(0)))
    return { pcm, playable: new Blob([wav], { type: 'audio/wav' }) }
  } catch (error) {
    throw new AudioDecodeError(`could not read "${name || 'file'}"`, { cause: originalError ?? error })
  }
}

const FFMPEG_VERSION = '0.12.15'
const FFMPEG_CORE_VERSION = '0.12.10'

async function transcodeToWav(buffer: ArrayBuffer, name: string): Promise<ArrayBuffer> {
  const { FFmpeg } = await import(/* @vite-ignore */ `https://cdn.jsdelivr.net/npm/@ffmpeg/ffmpeg@${FFMPEG_VERSION}/+esm`)
  const base = `https://cdn.jsdelivr.net/npm/@ffmpeg/core@${FFMPEG_CORE_VERSION}/dist/esm`
  const ffmpeg = new FFmpeg()
  await ffmpeg.load({ coreURL: `${base}/ffmpeg-core.js`, wasmURL: `${base}/ffmpeg-core.wasm` })
  const input = `input${(name.match(/\.[^.]+$/) ?? ['.bin'])[0]}`
  await ffmpeg.writeFile(input, new Uint8Array(buffer))
  await ffmpeg.exec(['-i', input, '-vn', '-ac', '1', '-ar', String(SAMPLE_RATE), '-c:a', 'pcm_s16le', '-f', 'wav', 'out.wav'])
  const data: Uint8Array = await ffmpeg.readFile('out.wav')
  ffmpeg.terminate()
  return data.slice().buffer as ArrayBuffer
}

/** Encodes PCM as a 16-bit WAV blob (used for playback when nothing else plays). */
export function pcmToWav(pcm: Float32Array, rate = SAMPLE_RATE): Blob {
  const buf = new ArrayBuffer(44 + pcm.length * 2)
  const v = new DataView(buf)
  const str = (o: number, s: string) => [...s].forEach((c, i) => v.setUint8(o + i, c.charCodeAt(0)))
  str(0, 'RIFF')
  v.setUint32(4, 36 + pcm.length * 2, true)
  str(8, 'WAVE')
  str(12, 'fmt ')
  v.setUint32(16, 16, true)
  v.setUint16(20, 1, true)
  v.setUint16(22, 1, true)
  v.setUint32(24, rate, true)
  v.setUint32(28, rate * 2, true)
  v.setUint16(32, 2, true)
  v.setUint16(34, 16, true)
  str(36, 'data')
  v.setUint32(40, pcm.length * 2, true)
  for (let i = 0; i < pcm.length; i++) {
    const s = Math.max(-1, Math.min(1, pcm[i]))
    v.setInt16(44 + i * 2, s < 0 ? s * 0x8000 : s * 0x7fff, true)
  }
  return new Blob([buf], { type: 'audio/wav' })
}
