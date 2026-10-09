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
  if (mem !== undefined && mem <= 2) return 'במכשיר הזה מעט זיכרון, וייתכן שהדפדפן ייסגר באמצע תמלול ארוך.'
  if (isLikelyMobile() && !hasWebGPU()) return 'הדפדפן הזה לא תומך ב־WebGPU, אז התמלול יהיה איטי יותר. עדיף לעדכן את המערכת או לנסות במחשב.'
  return null
}

/** iPhone/iPad (incl. iPadOS that reports itself as a Mac) or Android, from the user agent. */
export function mobileOS(): 'ios' | 'android' | null {
  const ua = navigator.userAgent
  if (/iPhone|iPad|iPod/.test(ua) || (navigator.maxTouchPoints > 1 && /Macintosh/.test(ua))) return 'ios'
  if (/Android/i.test(ua)) return 'android'
  return null
}

/**
 * What to tell people while recording. iOS suspends a backgrounded page and cuts
 * its microphone; Android Chrome keeps a tab's microphone running with the
 * screen off, as long as the tab itself stays open.
 */
export function recordingHint(): string | null {
  switch (mobileOS()) {
    case 'ios':
      return 'אל תכבו את המסך ואל תצאו מהדפדפן בזמן ההקלטה'
    case 'android':
      return 'אפשר לכבות את המסך, רק אל תסגרו את הדפדפן'
    default:
      return null
  }
}
