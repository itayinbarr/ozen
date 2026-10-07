/** Device capability hints. Warnings only; nothing is blocked. */

export function isLikelyMobile(): boolean {
  const data = (navigator as Navigator & { userAgentData?: { mobile?: boolean } }).userAgentData
  if (typeof data?.mobile === 'boolean') return data.mobile
  return /Android|iPhone|iPad|iPod|Mobile/i.test(navigator.userAgent) || (navigator.maxTouchPoints > 1 && /Macintosh/.test(navigator.userAgent))
}

export function deviceMemoryGB(): number | undefined {
  const v = (navigator as Navigator & { deviceMemory?: number }).deviceMemory
  return typeof v === 'number' ? v : undefined
}

export function hasWebGPU(): boolean {
  return typeof navigator !== 'undefined' && 'gpu' in navigator && !!(navigator as Navigator & { gpu?: unknown }).gpu
}

/** Hebrew warning to show on the home screen, or null. */
export function deviceWarning(): string | null {
  const mem = deviceMemoryGB()
  if (mem !== undefined && mem <= 2) return 'במכשיר הזה מעט זיכרון — ייתכן שהדפדפן ייסגר באמצע תמלול ארוך.'
  if (isLikelyMobile() && !hasWebGPU()) return 'הדפדפן הזה לא תומך ב־WebGPU, אז התמלול יהיה איטי יותר. עדיף לעדכן את המערכת או לנסות במחשב.'
  return null
}
