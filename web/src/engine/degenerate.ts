/**
 * Repetition-loop guard, ported from reference.is_degenerate. Whisper-style
 * decoders loop on one phrase when fed noise or music; such output is dropped.
 */
export function isDegenerate(text: string): boolean {
  const words = text.split(/\s+/).filter(Boolean)
  if (words.length < 12) return false
  for (let size = 1; size <= 4; size++) {
    if (words.length < size * 6) continue
    let repeats = 0
    for (let i = 0; i + size <= words.length; i += size) {
      let same = true
      for (let j = 0; j < size; j++) {
        if (words[i + j] !== words[j]) {
          same = false
          break
        }
      }
      if (same) repeats++
      else break
    }
    if (repeats * size > words.length * 0.7) return true
  }
  const counts = new Map<string, number>()
  for (const w of words) counts.set(w, (counts.get(w) ?? 0) + 1)
  let max = 0
  for (const c of counts.values()) max = Math.max(max, c)
  return max > words.length * 0.6 && words.length > 20
}
