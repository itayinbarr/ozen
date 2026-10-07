/** Small formatting helpers shared by the UI and the exporters. */

/** m:ss, or h:mm:ss for an hour or more (as in the design). */
export function fmt(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds))
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const x = s % 60
  const p = (n: number) => String(n).padStart(2, '0')
  return h ? `${h}:${p(m)}:${p(x)}` : `${m}:${p(x)}`
}

export function clock(d: Date): string {
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
}

/** "היום, 09:12" */
export function todayLabel(d = new Date()): string {
  return `היום, ${clock(d)}`
}

/** "עוד כ־12 שניות" / "עוד כ־3 דקות" */
export function remainingLabel(seconds: number): string {
  if (!Number.isFinite(seconds)) return 'מחשבים את הזמן…'
  const s = Math.max(1, Math.round(seconds))
  if (s < 90) return s === 1 ? 'עוד כשנייה' : `עוד כ־${s} שניות`
  const m = Math.round(s / 60)
  return `עוד כ־${m} דקות`
}

export function megabytes(bytes: number): string {
  return `${Math.round(bytes / 1e6)}MB`
}

/** File name without its extension. */
export function stem(name: string): string {
  return name.replace(/\.[^.]+$/, '') || name
}

/** Safe-ish file name (keeps Hebrew). */
export function safeFileName(name: string): string {
  return name.replace(/[\\/:*?"<>|\u0000-\u001f]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 80) || 'ozen'
}
