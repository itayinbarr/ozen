/**
 * GoatCounter custom events. Cookieless and aggregate; only event names are
 * sent, never audio, text or file names. Silently does nothing when blocked.
 */

interface GoatCounter {
  count?: (vars: { path: string; title?: string; event?: boolean }) => void
}

export type EventName = 'model-ready' | 'transcribe-done' | 'record-start' | 'import-file'

export function track(name: EventName | `transcribe-done-${string}`): void {
  try {
    const gc = (window as unknown as { goatcounter?: GoatCounter }).goatcounter
    gc?.count?.({ path: name, title: name, event: true })
  } catch {
    /* blocked or not loaded */
  }
}

export function lengthBucket(seconds: number): string {
  if (seconds < 60) return '<1m'
  if (seconds < 600) return '1-10m'
  return '10m+'
}
