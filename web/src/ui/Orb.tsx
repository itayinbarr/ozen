/**
 * The record orb: a disc with the ear drawn in, breathing when idle and moving
 * with the real microphone level while recording. Ported from the design's
 * rAF loop; `level()` supplies 0..1 loudness from an AnalyserNode.
 */

import { useEffect, useRef } from 'react'
import { EAR_I, EAR_O } from './icons.tsx'

export type RecState = 'idle' | 'rec' | 'paused'

interface Props {
  rec: RecState
  level: () => number
  onClick: () => void
  /** Bumped to replay the ear draw-in animation. */
  drawKey: number
  label: string
}

export function Orb({ rec, level, onClick, drawKey, label }: Props) {
  const ringRef = useRef<SVGCircleElement>(null)
  const discRef = useRef<SVGCircleElement>(null)
  const earGRef = useRef<SVGGElement>(null)
  const earORef = useRef<SVGPathElement>(null)
  const earIRef = useRef<SVGPathElement>(null)
  const sparkRef = useRef<SVGPathElement>(null)
  const recRef = useRef(rec)
  const levelRef = useRef(level)
  const drawT0 = useRef(performance.now())
  recRef.current = rec
  levelRef.current = level

  useEffect(() => {
    drawT0.current = performance.now()
  }, [drawKey])

  useEffect(() => {
    let raf = 0
    let lvl = 0
    let spPos = 0
    let last = performance.now()
    let LO = 0
    let LI = 0
    const loop = () => {
      raf = requestAnimationFrame(loop)
      const now = performance.now()
      const t = now / 1000
      const dt = Math.min(0.05, (now - last) / 1000)
      last = now
      const r = recRef.current
      const target = r === 'rec' ? levelRef.current() : 0
      lvl += (target - lvl) * 0.15
      const breath = (Math.sin(t * 1.4) + 1) / 2
      const hot = r === 'rec'
      const eg = earGRef.current
      if (eg) {
        const rot = hot ? Math.sin(t * 2.3) * 4 + lvl * 5 * Math.sin(t * 9) : Math.sin(t * 0.9) * 3
        const sc = 1.6 * (hot ? 1 + lvl * 0.09 : 1 + breath * 0.035)
        const dy = hot ? -lvl * 4 : Math.sin(t * 1.1) * 2.5
        eg.setAttribute('transform', `translate(140 ${(140 + dy).toFixed(2)}) rotate(${rot.toFixed(2)}) scale(${sc.toFixed(3)}) translate(-56 -50)`)
      }
      const d = discRef.current
      if (d) d.style.transform = `scale(${hot ? 1 + lvl * 0.045 : 1 + breath * 0.02})`
      const rg = ringRef.current
      if (rg) {
        rg.style.transform = `scale(${hot ? 1 + lvl * 0.1 : 1 + breath * 0.035})`
        rg.style.opacity = String(hot ? 0.25 + lvl * 0.4 : 0.28)
      }
      const eo = earORef.current
      const ei = earIRef.current
      const sp = sparkRef.current
      if (eo && ei) {
        if (!LO) {
          LO = eo.getTotalLength()
          LI = ei.getTotalLength()
        }
        const k = Math.min(1, (now - drawT0.current) / 1100)
        const e = 1 - Math.pow(1 - k, 3)
        eo.style.strokeDasharray = String(LO)
        eo.style.strokeDashoffset = String(LO * (1 - e))
        const k2 = Math.min(1, Math.max(0, (now - drawT0.current - 450) / 900))
        const e2 = 1 - Math.pow(1 - k2, 3)
        ei.style.strokeDasharray = String(LI)
        ei.style.strokeDashoffset = String(LI * (1 - e2))
        if (sp) {
          sp.style.opacity = hot && k >= 1 ? '.95' : '0'
          spPos += dt * (hot ? 70 + lvl * 90 : 0)
          sp.style.strokeDasharray = `12 ${LO + 30}`
          sp.style.strokeDashoffset = String(-(spPos % (LO + 30)))
        }
      }
    }
    loop()
    return () => cancelAnimationFrame(raf)
  }, [])

  const col = rec === 'rec' ? '#ff1b1c' : '#ff7f11'
  const tr = { transition: 'stroke .6s' }
  return (
    <button type="button" className="orb" onClick={onClick} aria-label={label}>
      <svg width="280" height="280" viewBox="0 0 280 280" aria-hidden="true">
        <circle ref={ringRef} cx="140" cy="140" r="134" fill="none" stroke={col} strokeWidth={1.5} style={{ ...tr, transformOrigin: '140px 140px', opacity: 0.28 }} />
        <circle ref={discRef} cx="140" cy="140" r="124" style={{ fill: 'var(--card)', transformOrigin: '140px 140px', transition: 'fill .4s' }} />
        <g ref={earGRef} transform="translate(140 140) scale(1.6) translate(-56 -50)">
          <path ref={earORef} d={EAR_O} fill="none" stroke={col} strokeWidth={6.5} strokeLinecap="round" strokeLinejoin="round" style={tr} />
          <path ref={earIRef} d={EAR_I} fill="none" stroke={col} strokeWidth={6.5} strokeLinecap="round" strokeLinejoin="round" style={tr} />
          <path ref={sparkRef} d={EAR_O} fill="none" stroke="#e2e8ce" strokeWidth={2.6} strokeLinecap="round" style={{ opacity: 0, transition: 'opacity .5s' }} />
        </g>
      </svg>
    </button>
  )
}
