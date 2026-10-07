/** Inline SVG icons from the design. */

export const EAR_O = 'M30 40C30 22 44 12 56 12C72 12 82 26 82 40C82 54 72 60 66 68C60 76 60 88 50 88C44 88 40 84 40 80'
export const EAR_I = 'M44 42C44 32 50 28 57 28C64 28 68 34 68 40C68 48 60 50 58 56'

const round = { strokeLinecap: 'round', strokeLinejoin: 'round' } as const

export function Logo() {
  return (
    <svg width="24" height="34" viewBox="24 6 64 88" fill="none" stroke="#ff7f11" strokeWidth={9} {...round} aria-hidden="true">
      <path d={EAR_O} />
      <path d={EAR_I} />
    </svg>
  )
}

export function ImportIcon() {
  return (
    <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.8} {...round} aria-hidden="true">
      <path d="M12 15V4M7.5 8.5L12 4l4.5 4.5M5 15v4h14v-4" />
    </svg>
  )
}

export function BackIcon() {
  return (
    <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} {...round} aria-hidden="true">
      <path d="M9 5l7 7-7 7" />
    </svg>
  )
}

export function SearchIcon({ size = 22, sw = 1.9 }: { size?: number; sw?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={sw} strokeLinecap="round" aria-hidden="true">
      <circle cx="10.5" cy="10.5" r="6" />
      <path d="M15 15l5 5" />
    </svg>
  )
}

export function CheckIcon({ size = 22, sw = 2.4 }: { size?: number; sw?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={sw} {...round} aria-hidden="true">
      <path d="M5 12.5l4.5 4.5L19 7.5" />
    </svg>
  )
}

export function PencilIcon() {
  return (
    <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.8} {...round} aria-hidden="true">
      <path d="M4.5 19.5h4l10-10-4-4-10 10z" />
    </svg>
  )
}

export function PlayIcon({ size = 18 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M7 4.5v15l12.5-7.5z" />
    </svg>
  )
}

export function PauseIcon({ size = 18 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <rect x="6" y="4.5" width="4" height="15" rx="1.2" />
      <rect x="14" y="4.5" width="4" height="15" rx="1.2" />
    </svg>
  )
}

export function CloseIcon({ size = 16 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2.2} strokeLinecap="round" aria-hidden="true">
      <path d="M6 6l12 12M18 6L6 18" />
    </svg>
  )
}

export function CopyIcon() {
  return (
    <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.9} strokeLinejoin="round" aria-hidden="true">
      <rect x="8.5" y="8.5" width="11" height="11" rx="2.5" />
      <path d="M15.5 8.5V6a1.5 1.5 0 0 0-1.5-1.5H6A1.5 1.5 0 0 0 4.5 6v8A1.5 1.5 0 0 0 6 15.5h2.5" />
    </svg>
  )
}

export function ShareIcon({ size = 22, opacity }: { size?: number; opacity?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.9} {...round} style={opacity ? { opacity } : undefined} aria-hidden="true">
      <path d="M12 14V4M7.5 8.5L12 4l4.5 4.5M5 13v6h14v-6" />
    </svg>
  )
}
