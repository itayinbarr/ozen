/**
 * Transcript screen (web mode): search with highlight, in-place editing, rename,
 * tap a paragraph to play from it, copy and export. Nothing is saved.
 */

import { useEffect, useMemo, useRef, useState, type CSSProperties } from 'react'
import { fmt } from '../lib/format.ts'
import { BackIcon, CheckIcon, CloseIcon, CopyIcon, PauseIcon, PencilIcon, PlayIcon, SearchIcon, ShareIcon } from './icons.tsx'

export interface DocSegment {
  /** Seconds. */
  start: number
  end: number
  text: string
}

export interface Doc {
  id: number
  title: string
  date: string
  duration: number
  segments: DocSegment[]
  audioUrl?: string
}

interface Props {
  doc: Doc | null
  active: boolean
  style: CSSProperties
  onBack: () => void
  onChange: (doc: Doc) => void
  onCopy: () => void
  onExport: () => void
  copied: boolean
}

const escapeRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

export function Transcript({ doc, active, style, onBack, onChange, onCopy, onExport, copied }: Props) {
  const [searchOpen, setSearchOpen] = useState(false)
  const [q, setQ] = useState('')
  const [editing, setEditing] = useState(false)
  const [titleEditing, setTitleEditing] = useState(false)
  const [titleDraft, setTitleDraft] = useState('')
  const [playIdx, setPlayIdx] = useState(-1)
  const [playing, setPlaying] = useState(false)
  const [pos, setPos] = useState(0)
  const audioRef = useRef<HTMLAudioElement>(null)
  const playIdxRef = useRef(-1)
  playIdxRef.current = playIdx
  const searchRef = useRef<HTMLInputElement>(null)

  // Reset view state for every new transcript.
  useEffect(() => {
    setSearchOpen(false)
    setQ('')
    setEditing(false)
    setTitleEditing(false)
    setPlayIdx(-1)
    setPlaying(false)
    setPos(0)
  }, [doc?.id])

  useEffect(() => {
    if (!active) {
      audioRef.current?.pause()
      setPlaying(false)
    }
  }, [active])

  const segs = doc?.segments ?? []
  const duration = doc?.duration ?? 0

  const query = searchOpen ? q.trim() : ''
  const { parts, matches } = useMemo(() => {
    let matches = 0
    const parts = segs.map((g) => {
      if (!query) return [{ t: g.text, hit: false }]
      const out: Array<{ t: string; hit: boolean }> = []
      g.text.split(new RegExp(`(${escapeRe(query)})`, 'gi')).forEach((t, j) => {
        if (!t) return
        const hit = j % 2 === 1
        if (hit) matches++
        out.push({ t, hit })
      })
      return out
    })
    return { parts, matches }
  }, [segs, query])

  const onTime = () => {
    const a = audioRef.current
    if (!a) return
    if (playIdxRef.current < 0) return // player closed
    const t = a.currentTime
    setPos(t)
    let idx = -1
    segs.forEach((g, i) => {
      if (g.start <= t + 0.05) idx = i
    })
    if (idx >= 0) setPlayIdx(idx)
  }

  const playFrom = (i: number) => {
    if (editing) return
    playIdxRef.current = i
    setPlayIdx(i)
    const a = audioRef.current
    if (!a || !doc?.audioUrl) return
    try {
      a.currentTime = segs[i].start
    } catch {
      /* not seekable yet */
    }
    setPos(segs[i].start)
    a.play().then(
      () => setPlaying(true),
      () => setPlaying(false),
    )
  }

  const togglePlay = () => {
    const a = audioRef.current
    if (!a) return
    if (a.paused) {
      if (a.ended) a.currentTime = 0
      a.play().then(
        () => setPlaying(true),
        () => setPlaying(false),
      )
    } else {
      a.pause()
      setPlaying(false)
    }
  }

  const closePlayer = () => {
    playIdxRef.current = -1
    audioRef.current?.pause()
    setPlaying(false)
    setPlayIdx(-1)
  }

  const toggleSearch = () => {
    const o = !searchOpen
    setSearchOpen(o)
    if (o) setTimeout(() => searchRef.current?.focus(), 250)
  }

  const toggleEdit = () => {
    setEditing((e) => !e)
    closePlayer()
  }

  const saveTitle = () => {
    if (!doc) return
    const t = titleDraft.trim() || doc.title
    setTitleEditing(false)
    if (t !== doc.title) onChange({ ...doc, title: t })
  }

  const editSeg = (i: number, text: string) => {
    if (!doc) return
    onChange({ ...doc, segments: doc.segments.map((g, k) => (k === i ? { ...g, text } : g)) })
  }

  const playLen = (audioRef.current?.duration && Number.isFinite(audioRef.current.duration) ? audioRef.current.duration : duration) || 1

  return (
    <section className="screen solid" style={style} aria-hidden={!active} inert={!active}>
      <div className="tr-head">
        <button type="button" className="icon-btn" onClick={onBack} aria-label="חזרה">
          <BackIcon />
        </button>
        <div className="tr-actions">
          <button
            type="button"
            className="icon-btn"
            onClick={toggleSearch}
            aria-label="חיפוש"
            aria-pressed={searchOpen}
            style={{ background: searchOpen ? 'var(--card)' : undefined }}
          >
            <SearchIcon />
          </button>
          <button
            type="button"
            className="icon-btn"
            onClick={toggleEdit}
            aria-label={editing ? 'סיום עריכה' : 'עריכה'}
            aria-pressed={editing}
            style={editing ? { background: '#ff7f11', color: '#262626' } : undefined}
          >
            {editing ? <CheckIcon /> : <PencilIcon />}
          </button>
        </div>
      </div>

      <div className="search-wrap" style={{ maxHeight: searchOpen ? 62 : 0 }}>
        <div className="search">
          <span style={{ opacity: 0.55, display: 'flex', flex: 'none' }}>
            <SearchIcon size={18} sw={2} />
          </span>
          <input
            ref={searchRef}
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="חיפוש"
            aria-label="חיפוש בתמלול"
            tabIndex={searchOpen ? 0 : -1}
            enterKeyHint="search"
          />
          <span className="count" dir="ltr" aria-live="polite">
            {query ? String(matches) : ''}
          </span>
        </div>
      </div>

      <div className="tr-title-wrap">
        {titleEditing ? (
          <input
            className="tr-title-input"
            value={titleDraft}
            onChange={(e) => setTitleDraft(e.target.value)}
            onBlur={saveTitle}
            onKeyDown={(e) => {
              if (e.key === 'Enter') (e.target as HTMLInputElement).blur()
            }}
            autoFocus
            aria-label="שם התמלול"
          />
        ) : (
          <div
            className="tr-title"
            role="button"
            tabIndex={0}
            aria-label={`שינוי שם: ${doc?.title ?? ''}`}
            onClick={() => {
              setTitleDraft(doc?.title ?? '')
              setTitleEditing(true)
            }}
            onKeyDown={(e) => {
              if (e.key === 'Enter') {
                setTitleDraft(doc?.title ?? '')
                setTitleEditing(true)
              }
            }}
          >
            {doc?.title}
          </div>
        )}
        <div className="tr-meta">
          <span>{doc ? `${doc.date} · ${fmt(doc.duration)}` : ''}</span>
          <span className="chip">לא נשמר, העתיקו או ייצאו</span>
        </div>
      </div>

      <div className="segs" data-testid="segments">
        {segs.length === 0 && doc && <div className="empty-tr">לא נמצא דיבור בהקלטה</div>}
        {segs.map((g, i) => (
          <div
            key={i}
            className={`seg${playIdx === i ? ' active' : ''}`}
            onClick={() => playFrom(i)}
            role={editing ? undefined : 'button'}
            tabIndex={editing ? undefined : 0}
            onKeyDown={(e) => {
              if (!editing && (e.key === 'Enter' || e.key === ' ')) {
                e.preventDefault()
                playFrom(i)
              }
            }}
          >
            <span className="seg-ts" dir="ltr">
              {fmt(g.start)}
            </span>
            {editing ? (
              <AutoTextarea value={g.text} onChange={(v) => editSeg(i, v)} />
            ) : (
              <div className="seg-text">
                {parts[i].map((p, j) => (p.hit ? <mark key={j}>{p.t}</mark> : <span key={j}>{p.t}</span>))}
              </div>
            )}
          </div>
        ))}
      </div>

      {doc?.audioUrl && (
        <audio
          ref={audioRef}
          src={doc.audioUrl}
          preload="metadata"
          onTimeUpdate={onTime}
          onPause={() => setPlaying(false)}
          onPlay={() => setPlaying(true)}
          onEnded={() => setPlaying(false)}
        />
      )}

      {playIdx >= 0 && (
        <div className="player">
          <button type="button" className="play" onClick={togglePlay} aria-label={playing ? 'השהיה' : 'ניגון'}>
            {playing ? <PauseIcon size={16} /> : <PlayIcon size={16} />}
          </button>
          <div className="track">
            <div style={{ width: `${Math.min(100, (pos / playLen) * 100)}%` }} />
          </div>
          <span className="time" dir="ltr">
            {fmt(pos)}
          </span>
          <button type="button" className="close" onClick={closePlayer} aria-label="סגירת הנגן">
            <CloseIcon />
          </button>
        </div>
      )}

      <div className="tr-foot">
        <button type="button" className={`copy-btn${copied ? ' copied' : ''}`} onClick={onCopy}>
          {copied ? (
            <span style={{ display: 'flex', animation: 'oz-fade .3s' }}>
              <CheckIcon />
            </span>
          ) : (
            <CopyIcon />
          )}
          <span>{copied ? 'הועתק' : 'העתקה'}</span>
        </button>
        <button type="button" className="export-btn" onClick={onExport} aria-label="ייצוא">
          <ShareIcon />
        </button>
      </div>
    </section>
  )
}

function AutoTextarea({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  const ref = useRef<HTMLTextAreaElement>(null)
  useEffect(() => {
    const el = ref.current
    if (!el) return
    // Fallback for browsers without `field-sizing: content`.
    if (!CSS.supports?.('field-sizing', 'content')) {
      el.style.height = 'auto'
      el.style.height = `${el.scrollHeight + 4}px`
    }
  }, [value])
  return <textarea ref={ref} value={value} dir="auto" onChange={(e) => onChange(e.target.value)} onClick={(e) => e.stopPropagation()} aria-label="עריכת קטע" />
}

