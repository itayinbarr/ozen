/** Keeps the screen awake while recording or transcribing, where supported. */

let sentinel: WakeLockSentinel | null = null
let wanted = false

async function acquire() {
  try {
    if (!wanted || sentinel || document.visibilityState !== 'visible') return
    sentinel = (await navigator.wakeLock?.request('screen')) ?? null
    sentinel?.addEventListener('release', () => {
      sentinel = null
    })
  } catch {
    sentinel = null
  }
}

if (typeof document !== 'undefined') {
  document.addEventListener('visibilitychange', () => void acquire())
}

export function keepAwake(on: boolean): void {
  wanted = on
  if (on) void acquire()
  else {
    sentinel?.release().catch(() => undefined)
    sentinel = null
  }
}
