/**
 * Ozen web app (design "web mode"): HOME (record / import), PROCESSING,
 * TRANSCRIPT. Nothing is saved: transcripts live in memory until the tab closes.
 */

import { useCallback, useEffect, useRef, useState, type CSSProperties } from 'react'
import { lengthBucket, track } from '../lib/analytics.ts'
import { ACCEPT_ATTRIBUTE, decodeAudio } from '../lib/audio.ts'
import { deviceWarning, recordingHint } from '../lib/device.ts'
import { CancelledError, EngineClient, type Job, type ModelState } from '../lib/engine.ts'
import { toMarkdown, toText } from '../lib/exporters.ts'
import { clock, fmt, megabytes, remainingLabel, safeFileName, stem, todayLabel } from '../lib/format.ts'
import { extensionFor, MicDeniedError, Recorder } from '../lib/recorder.ts'
import { keepAwake } from '../lib/wakelock.ts'
import { MODEL_FILES } from '../engine/constants.ts'
import { ImportIcon, Logo, PauseIcon, PlayIcon, ShareIcon, CloseIcon } from './icons.tsx'
import { Orb, type RecState } from './Orb.tsx'
import { Transcript, type Doc } from './Transcript.tsx'

/** Shown under the timer while recording on phones (see recordingHint). */
const REC_HINT = recordingHint()

type Screen = 'home' | 'proc' | 'tr'
type Sheet = null | 'import' | 'export' | 'about'

const DEPTH: Record<Screen, number> = { home: 0, proc: 1, tr: 2 }
const MODEL_BYTES = MODEL_FILES.reduce((a, f) => a + f.bytes, 0)
const SR = 16000

let engineSingleton: EngineClient | null = null
const getEngine = () => {
  if (!engineSingleton) {
    engineSingleton = new EngineClient()
    // Free the GPU device promptly on navigation instead of leaving it to GC.
    window.addEventListener('pagehide', (e) => {
      if (!e.persisted) engineSingleton?.dispose()
    })
  }
  return engineSingleton
}

interface ProcView {
  stage: 'decoding' | 'transcribing'
  progress: number
  remaining: number
  line: string
  lineKey: number
  source?: string
}

interface Tracker {
  weights: number[]
  total: number
  doneW: number
  cur: number
  curStart: number
  windowMs: number[]
}

function screenStyle(k: Screen, screen: Screen): CSSProperties {
  if (k === screen) return { transform: 'translateX(0)', opacity: 1, pointerEvents: 'auto' }
  if (k === 'proc') return { transform: 'scale(.9)', opacity: 0, pointerEvents: 'none' }
  if (DEPTH[k] < DEPTH[screen] || (screen === 'proc' && k === 'home')) return { transform: 'translateX(30%)', opacity: 0, pointerEvents: 'none' }
  return { transform: 'translateX(-100%)', opacity: 1, pointerEvents: 'none' }
}

/** Asks the service worker to keep the ONNX Runtime build we use for offline visits. */
function cacheRuntimeForOffline(webgpu: boolean) {
  if (!import.meta.env.PROD || !('serviceWorker' in navigator)) return
  const dir = `${import.meta.env.BASE_URL}ort/${__ORT_VERSION__}/`
  const stem = webgpu ? 'ort-wasm-simd-threaded.asyncify' : 'ort-wasm-simd-threaded'
  const urls = [`${dir}${stem}.mjs`, `${dir}${stem}.wasm`]
  navigator.serviceWorker.ready.then((reg) => reg.active?.postMessage({ type: 'cache', urls })).catch(() => undefined)
}

function saveData(): boolean {
  const c = (navigator as Navigator & { connection?: { saveData?: boolean } }).connection
  return !!c?.saveData
}

export function App() {
  const engine = getEngine()
  const [model, setModel] = useState<ModelState>(engine.state)
  const [screen, setScreen] = useState<Screen>('home')
  const [sheet, setSheet] = useState<Sheet>(null)
  const [rec, setRec] = useState<RecState>('idle')
  const [elapsed, setElapsed] = useState(0)
  const [drawKey, setDrawKey] = useState(0)
  const [proc, setProc] = useState<ProcView | null>(null)
  const [doc, setDoc] = useState<Doc | null>(null)
  const [toast, setToast] = useState<{ text: string; undo?: () => void; key: number } | null>(null)
  const [copied, setCopied] = useState(false)
  const [warning, setWarning] = useState<string | null>(() => deviceWarning())
  const [busy, setBusy] = useState(false)

  const recorder = useRef<Recorder | null>(null)
  const jobRef = useRef<Job | null>(null)
  const tracker = useRef<Tracker | null>(null)
  const fileInput = useRef<HTMLInputElement>(null)
  const toastTimer = useRef<number>(0)
  const copyTimer = useRef<number>(0)
  const announcedReady = useRef(false)
  const modelRef = useRef(model)
  modelRef.current = model

  const showToast = useCallback((text: string, undo?: () => void) => {
    window.clearTimeout(toastTimer.current)
    setToast({ text, undo, key: Date.now() })
    toastTimer.current = window.setTimeout(() => setToast(null), undo ? 4200 : 2400)
  }, [])

  // ---------------------------------------------------------------- model
  useEffect(() => {
    const off = engine.subscribe(setModel)
    if (!saveData()) engine.load()
    try {
      void navigator.storage?.persist?.()
    } catch {
      /* not supported */
    }
    return () => {
      off()
    }
  }, [engine])

  // Exposed for diagnostics and the e2e tests.
  useEffect(() => {
    const d = document.documentElement.dataset
    d.ozenModel = model.phase
    if (model.backend) d.ozenBackend = model.decoderBackend && model.decoderBackend !== model.backend ? `${model.backend}+${model.decoderBackend}-decoder` : model.backend
  }, [model.phase, model.backend, model.decoderBackend])

  useEffect(() => {
    if (model.phase === 'ready' && !announcedReady.current) {
      announcedReady.current = true
      cacheRuntimeForOffline(model.backend === 'webgpu')
      if (!model.fromCache) {
        track('model-ready')
        showToast('המודל מוכן · מעכשיו עובד גם בלי אינטרנט')
      }
    }
  }, [model.phase, model.fromCache, showToast])

  // ---------------------------------------------------------------- recording
  useEffect(() => {
    if (rec === 'idle') return
    const id = window.setInterval(() => setElapsed(recorder.current?.elapsed() ?? 0), 250)
    return () => window.clearInterval(id)
  }, [rec])

  const level = useCallback(() => recorder.current?.level() ?? 0, [])

  // Warn before closing the tab with unsaved work.
  useEffect(() => {
    const dirty = rec !== 'idle' || screen === 'proc' || (screen === 'tr' && !!doc)
    if (!dirty) return
    const h = (e: BeforeUnloadEvent) => {
      e.preventDefault()
      e.returnValue = ''
    }
    window.addEventListener('beforeunload', h)
    return () => window.removeEventListener('beforeunload', h)
  }, [rec, screen, doc])

  // ---------------------------------------------------------------- processing
  const updateProgress = useCallback(() => {
    const t = tracker.current
    if (!t) return
    const m = modelRef.current
    const defMs = m.backend === 'webgpu' ? 2500 : 11000
    const avg = t.windowMs.length ? t.windowMs.reduce((a, b) => a + b, 0) / t.windowMs.length : defMs
    let frac = 0
    let remaining = Infinity
    if (t.weights.length) {
      const inCur = t.cur >= 0 ? Math.min(0.95, (performance.now() - t.curStart) / avg) : 0
      const curW = t.cur >= 0 ? t.weights[t.cur] : 0
      frac = (t.doneW + curW * inCur) / t.total
      const left = t.weights.length - t.windowMs.length - (t.cur >= 0 ? inCur : 0)
      remaining = t.windowMs.length || m.phase === 'ready' ? Math.max(0, (left * avg) / 1000) : Infinity
    }
    setProc((p) => (p && p.stage === 'transcribing' ? { ...p, progress: Math.max(p.progress, Math.min(1, frac)), remaining } : p))
  }, [])

  useEffect(() => {
    if (screen !== 'proc') return
    const id = window.setInterval(updateProgress, 250)
    return () => window.clearInterval(id)
  }, [screen, updateProgress])

  const runPipeline = useCallback(
    async (blob: Blob, name: string, title: string, source?: string) => {
      if (busy) return
      setBusy(true)
      setSheet(null)
      setScreen('proc')
      setProc({ stage: 'decoding', progress: 0, remaining: Infinity, line: '', lineKey: 0, source })
      keepAwake(true)
      if (modelRef.current.phase === 'idle' || modelRef.current.phase === 'error') engine.load()
      try {
        let decoded
        try {
          decoded = await decodeAudio(blob, name)
        } catch (e) {
          console.warn('[ozen] decode failed', e)
          showToast('לא הצלחנו לקרוא את הקובץ')
          setScreen('home')
          return
        }
        const duration = decoded.pcm.length / SR
        if (duration < 0.3) {
          showToast('ההקלטה קצרה מדי')
          setScreen('home')
          return
        }
        const audioUrl = URL.createObjectURL(decoded.playable ?? blob)
        tracker.current = { weights: [], total: 1, doneW: 0, cur: -1, curStart: 0, windowMs: [] }
        setProc((p) => (p ? { ...p, stage: 'transcribing' } : p))
        const job = engine.transcribe(decoded.pcm, {
          onPlan: (ranges) => {
            const t = tracker.current!
            t.weights = ranges.map(([a, b]) => b - a)
            t.total = Math.max(1, t.weights.reduce((a, b) => a + b, 0))
          },
          onWindowStart: (i) => {
            const t = tracker.current!
            t.cur = i
            t.curStart = performance.now()
          },
          onWindowDone: (i, seg, ms) => {
            const t = tracker.current!
            t.doneW += t.weights[i] ?? 0
            t.windowMs.push(ms)
            t.cur = -1
            if (seg) setProc((p) => (p ? { ...p, line: seg.text, lineKey: p.lineKey + 1 } : p))
            updateProgress()
          },
        })
        jobRef.current = job
        let result
        try {
          result = await job.done
        } catch (e) {
          URL.revokeObjectURL(audioUrl)
          if (e instanceof CancelledError) showToast('התמלול בוטל')
          else {
            console.error('[ozen] transcription failed', e)
            showToast(modelRef.current.phase === 'error' ? 'לא הצלחנו להוריד את המודל' : 'משהו השתבש בתמלול')
          }
          setScreen('home')
          return
        }
        setProc((p) => (p ? { ...p, progress: 1, remaining: 0 } : p))
        track('transcribe-done')
        track(`transcribe-done-${lengthBucket(duration)}`)
        if (result.segments.length === 0) {
          URL.revokeObjectURL(audioUrl)
          showToast('לא נמצא דיבור בהקלטה')
          setScreen('home')
          return
        }
        setDoc((old) => {
          if (old?.audioUrl) URL.revokeObjectURL(old.audioUrl)
          return {
            id: Date.now(),
            title,
            date: todayLabel(),
            duration,
            segments: result.segments.map((s) => ({ start: s.start / SR, end: s.end / SR, text: s.text })),
            audioUrl,
          }
        })
        await new Promise((r) => setTimeout(r, 400))
        setScreen('tr')
      } finally {
        jobRef.current = null
        tracker.current = null
        keepAwake(false)
        setBusy(false)
      }
    },
    [busy, engine, showToast, updateProgress],
  )

  const cancelJob = () => jobRef.current?.cancel()

  // ---------------------------------------------------------------- record button
  const toggleRec = async () => {
    if (screen !== 'home') return
    if (rec === 'idle') {
      if (busy) return
      if (!Recorder.supported()) {
        showToast('הדפדפן הזה לא תומך בהקלטה')
        return
      }
      const r = new Recorder()
      try {
        await r.start()
      } catch (e) {
        showToast(e instanceof MicDeniedError ? 'אין גישה למיקרופון' : 'לא הצלחנו להתחיל הקלטה')
        return
      }
      recorder.current = r
      setElapsed(0)
      setDrawKey((k) => k + 1)
      setRec('rec')
      keepAwake(true)
      track('record-start')
      if (modelRef.current.phase === 'idle' || modelRef.current.phase === 'error') engine.load()
    } else {
      const r = recorder.current
      if (!r) return
      const secs = r.elapsed()
      setRec('idle')
      recorder.current = null
      let blob: Blob
      try {
        blob = await r.stop()
      } catch {
        keepAwake(false)
        showToast('ההקלטה נכשלה')
        return
      }
      setElapsed(secs)
      const now = new Date()
      void runPipeline(blob, `recording.${extensionFor(blob.type)}`, `הקלטה ${clock(now)}`)
    }
  }

  const togglePause = () => {
    const r = recorder.current
    if (!r) return
    if (rec === 'rec') {
      r.pause()
      setRec('paused')
    } else {
      r.resume()
      setRec('rec')
    }
  }

  // ---------------------------------------------------------------- import
  const onFile = (file: File | undefined) => {
    if (!file) return
    if (rec !== 'idle') {
      setSheet(null)
      showToast('קודם מסיימים את ההקלטה')
      return
    }
    track('import-file')
    void runPipeline(file, file.name, stem(file.name), file.name)
  }

  useEffect(() => {
    // Desktop: drop a file anywhere.
    const over = (e: DragEvent) => {
      if (e.dataTransfer?.types.includes('Files')) e.preventDefault()
    }
    const drop = (e: DragEvent) => {
      const f = e.dataTransfer?.files?.[0]
      if (!f) return
      e.preventDefault()
      if (screen === 'home') onFile(f)
    }
    window.addEventListener('dragover', over)
    window.addEventListener('drop', drop)
    return () => {
      window.removeEventListener('dragover', over)
      window.removeEventListener('drop', drop)
    }
  })

  // ---------------------------------------------------------------- transcript actions
  const copyAll = async () => {
    if (!doc) return
    const text = toText(doc)
    let ok = false
    try {
      await navigator.clipboard.writeText(text)
      ok = true
    } catch {
      const ta = document.createElement('textarea')
      ta.value = text
      ta.setAttribute('readonly', '')
      ta.style.position = 'fixed'
      ta.style.opacity = '0'
      document.body.appendChild(ta)
      ta.select()
      try {
        ok = document.execCommand('copy')
      } catch {
        ok = false
      }
      ta.remove()
    }
    if (!ok) {
      showToast('ההעתקה נכשלה')
      return
    }
    window.clearTimeout(copyTimer.current)
    setCopied(true)
    copyTimer.current = window.setTimeout(() => setCopied(false), 1800)
  }

  const download = (ext: 'txt' | 'md') => {
    if (!doc) return
    const name = `${safeFileName(doc.title)}.${ext}`
    const blob = new Blob([ext === 'md' ? toMarkdown(doc) : toText(doc)], { type: ext === 'md' ? 'text/markdown;charset=utf-8' : 'text/plain;charset=utf-8' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = name
    document.body.appendChild(a)
    a.click()
    a.remove()
    setTimeout(() => URL.revokeObjectURL(url), 10000)
    setSheet(null)
    showToast(`נשמר ${name}`)
  }

  const canShare = typeof navigator !== 'undefined' && typeof navigator.share === 'function'
  const shareOut = () => {
    if (!doc) return
    setSheet(null)
    navigator.share?.({ title: doc.title, text: toText(doc) }).catch(() => undefined)
  }

  const backFromTr = () => {
    setScreen('home')
    showToast('התמלול נסגר', () => {
      setScreen('tr')
      setToast(null)
    })
  }

  // ---------------------------------------------------------------- render helpers
  const recording = rec !== 'idle'
  const recHint = REC_HINT
  const orbHint = rec === 'idle' ? 'לחצו להתחלת הקלטה' : rec === 'paused' ? 'מושהה · לחצו לסיום' : 'לחצו לסיום'

  const downloading = model.phase === 'loading' && !model.fromCache
  const pct = model.total ? Math.floor((model.loaded / model.total) * 100) : 0

  // Processing screen content depends on whether the model is still arriving.
  let ringFrac = proc?.progress ?? 0
  let procTitle = 'מתמלל'
  let procSub = remainingLabel(proc?.remaining ?? Infinity)
  if (proc?.stage === 'decoding') {
    procTitle = 'מכינים את השמע'
    procSub = 'רגע אחד…'
  } else if (model.phase === 'loading' && proc && proc.progress === 0) {
    if (model.fromCache) {
      procTitle = 'טוענים את המודל'
      procSub = 'רגע אחד…'
    } else {
      ringFrac = model.total ? model.loaded / model.total : 0
      procTitle = 'מורידים את המודל'
      procSub = `${megabytes(model.loaded)} מתוך כ־${Math.round(MODEL_BYTES / 1e6)}MB · נשמר בדפדפן`
    }
  } else if (model.phase === 'compiling' && proc && proc.progress === 0) {
    procTitle = 'מכינים את המודל'
    procSub = 'בפעם הראשונה זה לוקח קצת יותר'
  } else if (proc && proc.progress >= 1) {
    procSub = 'מוכן'
  }

  const toastBottom = screen === 'tr' ? 112 : 28

  return (
    <div className="app" dir="rtl" lang="he">
      <div className="stage">
        {/* HOME */}
        <section className="screen" style={screenStyle('home', screen)} aria-hidden={screen !== 'home'} inert={screen !== 'home'}>
          <header className="home-head">
            <div className="brand">
              <Logo />
              <h1 className="brand-word" style={{ margin: 0 }}>
                אוזן
              </h1>
            </div>
            <div className="head-actions">
              <button type="button" className="icon-btn" onClick={() => setSheet('import')} aria-label="ייבוא שמע">
                <ImportIcon />
              </button>
            </div>
          </header>

          {screen === 'home' && (
            <div className="notes">
              {model.phase === 'idle' && (
                <div className="note">
                  <div className="note-row">
                    <span>
                      צריך להוריד את המודל פעם אחת · <bdi dir="ltr">~{Math.round(MODEL_BYTES / 1e6)}MB</bdi> · נשמר בדפדפן
                    </span>
                    <button type="button" className="note-btn" onClick={() => engine.load()}>
                      הורדה
                    </button>
                  </div>
                </div>
              )}
              {downloading && (
                <div className="note" role="status" data-testid="download-card">
                  <div className="note-row">
                    <span>
                      מורידים את המודל · <bdi dir="ltr">~{Math.round(MODEL_BYTES / 1e6)}MB</bdi> · נשמר בדפדפן
                    </span>
                    <span className="note-pct" dir="ltr">
                      {pct}%
                    </span>
                  </div>
                  <div className="bar">
                    <div style={{ width: `${pct}%` }} />
                  </div>
                </div>
              )}
              {model.phase === 'compiling' && !model.fromCache && (
                <div className="note" role="status">
                  <div className="note-row">
                    <span>מכינים את המודל…</span>
                  </div>
                  <div className="bar">
                    <div style={{ width: '100%', opacity: 0.5, animation: 'oz-blink 1.4s infinite' }} />
                  </div>
                </div>
              )}
              {model.phase === 'error' && (
                <div className="note" role="alert">
                  <div className="note-row">
                    <span>
                      {model.offline
                        ? 'אין חיבור לאינטרנט. צריך חיבור כדי להוריד את המודל בפעם הראשונה.'
                        : 'הורדת המודל נכשלה.'}
                    </span>
                    <button type="button" className="note-btn" onClick={() => engine.load()}>
                      לנסות שוב
                    </button>
                  </div>
                </div>
              )}
              {warning && !recording && (
                <div className="note">
                  <div className="note-row">
                    <span className="note-sub">{warning}</span>
                    <button type="button" className="note-x" onClick={() => setWarning(null)} aria-label="סגירה">
                      <CloseIcon />
                    </button>
                  </div>
                </div>
              )}
            </div>
          )}

          <div className="home-center">
            <div className={`timer${rec === 'paused' ? ' paused' : ''}`} dir="ltr" style={{ opacity: recording ? 1 : 0 }} aria-hidden={!recording}>
              {fmt(elapsed)}
            </div>
            <div className="rec-hint" style={{ opacity: recording && recHint ? 1 : 0 }} aria-hidden={!recording || !recHint}>
              {recHint}
            </div>
            <div className="orb-wrap">
              <Orb rec={rec} level={level} onClick={() => void toggleRec()} drawKey={drawKey} label={rec === 'idle' ? 'התחלת הקלטה' : 'סיום הקלטה'} />
            </div>
            <div className="orb-hint" aria-live="polite">
              {orbHint}
            </div>
          </div>

          <div className="home-foot">
            {recording ? (
              <button type="button" className="round-btn" onClick={togglePause} aria-label={rec === 'paused' ? 'המשך הקלטה' : 'השהיית הקלטה'}>
                {rec === 'paused' ? <PlayIcon /> : <PauseIcon />}
              </button>
            ) : (
              <button type="button" className="about-link" onClick={() => setSheet('about')}>
                אודות · פרטיות
              </button>
            )}
          </div>
        </section>

        {/* PROCESSING */}
        <section className="screen proc" style={screenStyle('proc', screen)} aria-hidden={screen !== 'proc'} inert={screen !== 'proc'}>
          <div className="ring" role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.floor(ringFrac * 100)} aria-label={procTitle}>
            <div className="ring-core" />
            <svg width="230" height="230" viewBox="0 0 230 230" aria-hidden="true">
              <circle cx="115" cy="115" r="104" fill="none" stroke="var(--line)" strokeWidth={5} />
              <circle
                cx="115"
                cy="115"
                r="104"
                fill="none"
                stroke="#ff7f11"
                strokeWidth={5}
                strokeLinecap="round"
                strokeDasharray={653.5}
                strokeDashoffset={653.5 * (1 - ringFrac)}
                style={{ transition: 'stroke-dashoffset .25s linear' }}
              />
            </svg>
            <div className="ring-pct" dir="ltr">
              {Math.floor(ringFrac * 100)}%
            </div>
          </div>
          <div className="proc-title">
            <div>{procTitle}</div>
            <div>{procSub}</div>
          </div>
          <div className="proc-line" aria-live="polite">
            {proc?.line ? <div key={proc.lineKey}>{proc.line}</div> : null}
          </div>
          <div className="proc-bottom">
            {proc?.source && (
              <div className="source-chip" dir="ltr">
                <span />
                <span dir="ltr">{proc.source}</span>
              </div>
            )}
            <button type="button" className="text-btn" onClick={cancelJob} disabled={proc?.stage !== 'transcribing'} style={{ opacity: proc?.stage === 'transcribing' ? 1 : 0 }}>
              ביטול
            </button>
          </div>
        </section>

        {/* TRANSCRIPT */}
        <Transcript
          doc={doc}
          active={screen === 'tr'}
          style={screenStyle('tr', screen)}
          onBack={backFromTr}
          onChange={setDoc}
          onCopy={() => void copyAll()}
          onExport={() => setSheet('export')}
          copied={copied}
        />

        {toast && (
          <div className="toast" key={toast.key} style={{ bottom: `calc(${toastBottom}px + env(safe-area-inset-bottom))` }} role="status">
            <span>{toast.text}</span>
            {toast.undo && (
              <button type="button" onClick={toast.undo}>
                ביטול
              </button>
            )}
          </div>
        )}
      </div>

      <input
        ref={fileInput}
        type="file"
        accept={ACCEPT_ATTRIBUTE}
        className="sr-only"
        tabIndex={-1}
        aria-hidden="true"
        data-testid="file-input"
        onChange={(e) => {
          onFile(e.target.files?.[0])
          e.target.value = ''
        }}
      />

      {sheet && (
        <>
          <div className="scrim" onClick={() => setSheet(null)} />
          <div className="sheet" role="dialog" aria-modal="true" aria-label={sheet === 'import' ? 'ייבוא שמע' : sheet === 'export' ? 'ייצוא' : 'אודות'}>
            <div className="grabber" />
            {sheet === 'import' && (
              <>
                <div className="sheet-title">ייבוא שמע</div>
                <button type="button" className="primary-btn" onClick={() => fileInput.current?.click()}>
                  בחירת קובץ
                </button>
                <div className="hint">אפשר גם הודעות קוליות מוואטסאפ: שתפו אותן לקבצים ובחרו מכאן</div>
              </>
            )}
            {sheet === 'export' && (
              <>
                <div className="sheet-title">ייצוא</div>
                <button type="button" className="sheet-row" onClick={() => download('txt')}>
                  <span>טקסט</span>
                  <span className="ext" dir="ltr">
                    .txt
                  </span>
                </button>
                <button type="button" className="sheet-row" onClick={() => download('md')}>
                  <span>Markdown</span>
                  <span className="ext" dir="ltr">
                    .md
                  </span>
                </button>
                {canShare && (
                  <button type="button" className="sheet-row" onClick={shareOut}>
                    <span>שיתוף…</span>
                    <ShareIcon size={20} opacity={0.6} />
                  </button>
                )}
              </>
            )}
            {sheet === 'about' && <About />}
          </div>
        </>
      )}
    </div>
  )
}

function About() {
  const base = import.meta.env.BASE_URL
  return (
    <>
      <div className="sheet-title">אוזן</div>
      <div className="about-text">
        <p>תמלול בעברית שרץ על המכשיר שלכם. השמע והטקסט לא עולים לשום שרת ולא נשמרים בשום מקום.</p>
      </div>
      <div className="about-links">
        <a className="sheet-row" href={`${base}privacy.html`}>
          פרטיות
        </a>
      </div>
    </>
  )
}
