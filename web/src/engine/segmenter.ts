/**
 * Pause-based paragraph segmenter. Implements spec/segmenter.md exactly; the
 * iOS and Python implementations must produce identical cut points on
 * spec/segmenter-vectors.json. All energy math is float64.
 */

export const FRAME = 480
export const BRIDGE = 17
export const PAD = 5
export const MIN_SPEECH = 7
export const TARGET_MAX = 667
export const HARD_MAX = 933
export const SPLIT_FROM = 500
export const PARA_GAP = 50
export const MIN_SEG = 67

/** Per-frame energy in dB: 10*log10(mean(x^2) + 1e-10). */
export function frameDb(x: ArrayLike<number>): Float64Array {
  const N = x.length
  const n = Math.ceil(N / FRAME)
  const out = new Float64Array(n)
  for (let i = 0; i < n; i++) {
    const a = i * FRAME
    const b = Math.min((i + 1) * FRAME, N)
    let sum = 0
    for (let j = a; j < b; j++) {
      const v = x[j]
      sum += v * v
    }
    out[i] = 10 * Math.log10(sum / (b - a) + 1e-10)
  }
  return out
}

type Run = [number, number]

/** Paragraph cut points as half-open sample ranges [start, end). */
export function segment(x: ArrayLike<number>): Array<[number, number]> {
  const N = x.length
  if (N === 0) return []
  const db = frameDb(x)
  const n = db.length

  // 2. threshold
  const sorted = Float64Array.from(db).sort()
  const noise = sorted[Math.floor(0.1 * (n - 1))]
  const peak = sorted[Math.floor(0.95 * (n - 1))]
  if (peak < -55) return []
  const thr = noise + Math.max(6.0, 0.35 * (peak - noise))

  // 3. runs of voiced frames
  const runs: Run[] = []
  for (let i = 0; i < n; ) {
    if (db[i] > thr) {
      let j = i
      while (j < n && db[j] > thr) j++
      runs.push([i, j])
      i = j
    } else {
      i++
    }
  }

  // 4. bridge short silences
  const bridged: Run[] = []
  for (const r of runs) {
    const last = bridged[bridged.length - 1]
    if (last && r[0] - last[1] < BRIDGE) last[1] = r[1]
    else bridged.push([r[0], r[1]])
  }

  // 5. drop blips
  const kept = bridged.filter((r) => r[1] - r[0] >= MIN_SPEECH)

  // 6. pad and merge touching runs
  const padded: Run[] = []
  for (const r of kept) {
    const a = Math.max(0, r[0] - PAD)
    const b = Math.min(n, r[1] + PAD)
    const last = padded[padded.length - 1]
    if (last && a <= last[1]) last[1] = Math.max(last[1], b)
    else padded.push([a, b])
  }

  // 7. split over-long runs at their quietest frame
  const split: Run[] = []
  for (const r of padded) {
    let a = r[0]
    const b = r[1]
    while (b - a > HARD_MAX) {
      const lo = a + SPLIT_FROM
      const hi = a + HARD_MAX
      let k = lo
      for (let j = lo; j < hi; j++) if (db[j] < db[k]) k = j
      split.push([a, k])
      a = k
    }
    split.push([a, b])
  }

  // 8. pack into paragraphs
  const paras: Run[] = []
  for (const r of split) {
    const cur = paras[paras.length - 1]
    if (!cur) {
      paras.push([r[0], r[1]])
      continue
    }
    if (r[0] - cur[1] < PARA_GAP && r[1] - cur[0] <= TARGET_MAX) cur[1] = r[1]
    else paras.push([r[0], r[1]])
  }

  // 9. absorb short paragraphs into a neighbour
  let changed = true
  while (changed) {
    changed = false
    for (let idx = 0; idx < paras.length; idx++) {
      const p = paras[idx]
      if (p[1] - p[0] >= MIN_SEG) continue
      if (idx > 0 && p[1] - paras[idx - 1][0] <= HARD_MAX) {
        paras[idx - 1][1] = p[1]
        paras.splice(idx, 1)
        changed = true
        break
      }
      if (idx + 1 < paras.length && paras[idx + 1][1] - p[0] <= HARD_MAX) {
        paras[idx + 1][0] = p[0]
        paras.splice(idx, 1)
        changed = true
        break
      }
    }
  }

  // 10. back to samples
  return paras.map(([a, b]) => [a * FRAME, Math.min(b * FRAME, N)])
}
