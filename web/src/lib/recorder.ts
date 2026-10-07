/**
 * Microphone recording with pause/resume and a live level meter.
 * MediaRecorder gives mp4/aac on Safari and webm/opus on Chrome/Android; both
 * decode with decodeAudioData afterwards.
 */

const TYPES = ['audio/webm;codecs=opus', 'audio/mp4', 'audio/webm', 'audio/ogg;codecs=opus', 'audio/mp4;codecs=mp4a.40.2']

export class MicDeniedError extends Error {
  constructor(cause?: unknown) {
    super('microphone permission denied', { cause })
    this.name = 'MicDeniedError'
  }
}

export class Recorder {
  private stream: MediaStream | null = null
  private recorder: MediaRecorder | null = null
  private chunks: Blob[] = []
  private ctx: AudioContext | null = null
  private analyser: AnalyserNode | null = null
  private buf: Float32Array<ArrayBuffer> | null = null
  private startedAt = 0
  private accumulated = 0
  mimeType = ''

  static supported(): boolean {
    return typeof navigator !== 'undefined' && !!navigator.mediaDevices?.getUserMedia && typeof MediaRecorder !== 'undefined'
  }

  async start(): Promise<void> {
    // Create and resume the meter's AudioContext synchronously, while we are still
    // inside the tap: iOS Safari keeps contexts created after an await suspended.
    try {
      const Ctx: typeof AudioContext =
        window.AudioContext ?? (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext
      this.ctx = new Ctx()
      void this.ctx.resume().catch(() => undefined)
    } catch {
      this.ctx = null
    }
    try {
      this.stream = await navigator.mediaDevices.getUserMedia({
        audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true },
      })
    } catch (e) {
      this.cleanup()
      throw new MicDeniedError(e)
    }
    const type = TYPES.find((t) => MediaRecorder.isTypeSupported?.(t))
    this.recorder = new MediaRecorder(this.stream, type ? { mimeType: type } : undefined)
    this.mimeType = this.recorder.mimeType || type || ''
    this.chunks = []
    this.recorder.ondataavailable = (e) => {
      if (e.data && e.data.size) this.chunks.push(e.data)
    }
    this.recorder.start(1000)
    this.startedAt = performance.now()
    this.accumulated = 0
    try {
      if (this.ctx) {
        const src = this.ctx.createMediaStreamSource(this.stream)
        this.analyser = this.ctx.createAnalyser()
        this.analyser.fftSize = 1024
        src.connect(this.analyser)
        this.buf = new Float32Array(this.analyser.fftSize)
        if (this.ctx.state === 'suspended') await this.ctx.resume().catch(() => undefined)
      }
    } catch {
      this.analyser = null
    }
  }

  get paused(): boolean {
    return this.recorder?.state === 'paused'
  }

  pause(): void {
    if (this.recorder?.state === 'recording') {
      this.recorder.pause()
      this.accumulated += performance.now() - this.startedAt
    }
  }

  resume(): void {
    if (this.recorder?.state === 'paused') {
      this.recorder.resume()
      this.startedAt = performance.now()
    }
  }

  /** Seconds recorded so far (excluding pauses). */
  elapsed(): number {
    if (!this.recorder) return 0
    const live = this.recorder.state === 'recording' ? performance.now() - this.startedAt : 0
    return (this.accumulated + live) / 1000
  }

  /** 0..1 loudness of the last ~60 ms. */
  level(): number {
    if (!this.analyser || !this.buf || this.paused) return 0
    this.analyser.getFloatTimeDomainData(this.buf)
    let s = 0
    for (let i = 0; i < this.buf.length; i++) s += this.buf[i] * this.buf[i]
    const rms = Math.sqrt(s / this.buf.length)
    const db = 20 * Math.log10(rms + 1e-9)
    return Math.max(0, Math.min(1, (db + 55) / 40))
  }

  async stop(): Promise<Blob> {
    const rec = this.recorder
    if (!rec) throw new Error('not recording')
    const done = new Promise<void>((resolve) => {
      rec.addEventListener('stop', () => resolve(), { once: true })
    })
    if (rec.state !== 'inactive') rec.stop()
    await done
    const blob = new Blob(this.chunks, { type: this.mimeType || this.chunks[0]?.type || 'audio/webm' })
    this.cleanup()
    return blob
  }

  cancel(): void {
    try {
      if (this.recorder && this.recorder.state !== 'inactive') this.recorder.stop()
    } catch {
      /* ignore */
    }
    this.cleanup()
  }

  private cleanup() {
    this.stream?.getTracks().forEach((t) => t.stop())
    this.ctx?.close().catch(() => undefined)
    this.stream = null
    this.recorder = null
    this.ctx = null
    this.analyser = null
    this.chunks = []
  }
}

export function extensionFor(mime: string): string {
  if (mime.includes('mp4') || mime.includes('aac')) return 'm4a'
  if (mime.includes('ogg')) return 'ogg'
  return 'webm'
}
