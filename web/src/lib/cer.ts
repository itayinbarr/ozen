/** Character error rate: Levenshtein distance over code points / reference length. */
export function cer(reference: string, hypothesis: string): number {
  const r = Array.from(reference)
  const h = Array.from(hypothesis)
  if (r.length === 0) return h.length ? 1 : 0
  let prev = new Array<number>(h.length + 1)
  let cur = new Array<number>(h.length + 1)
  for (let j = 0; j <= h.length; j++) prev[j] = j
  for (let i = 1; i <= r.length; i++) {
    cur[0] = i
    for (let j = 1; j <= h.length; j++) {
      cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] === h[j - 1] ? 0 : 1))
    }
    ;[prev, cur] = [cur, prev]
  }
  return prev[h.length] / r.length
}
