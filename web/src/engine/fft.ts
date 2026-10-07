/**
 * Small mixed-radix complex FFT (Cooley-Tukey, decimation in time) for sizes
 * whose prime factors are 2, 3, 4, 5... Used for Whisper's N=400 frames
 * (400 = 4*4*5*5). Float64 throughout so it matches numpy.fft to ~1e-12.
 */

export class FFT {
  readonly n: number
  private readonly factors: number[]
  private readonly cos: Float64Array
  private readonly sin: Float64Array
  private readonly tRe: Float64Array
  private readonly tIm: Float64Array

  constructor(n: number) {
    this.n = n
    this.factors = factorize(n)
    this.cos = new Float64Array(n)
    this.sin = new Float64Array(n)
    for (let i = 0; i < n; i++) {
      const a = (-2 * Math.PI * i) / n
      this.cos[i] = Math.cos(a)
      this.sin[i] = Math.sin(a)
    }
    const maxP = Math.max(...this.factors, 1)
    this.tRe = new Float64Array(maxP)
    this.tIm = new Float64Array(maxP)
  }

  /** out = DFT(in). Input and output must be distinct arrays of length n. */
  transform(inRe: Float64Array, inIm: Float64Array, outRe: Float64Array, outIm: Float64Array): void {
    this.rec(this.n, inRe, inIm, 0, 1, outRe, outIm, 0, 0)
  }

  private rec(
    n: number,
    inRe: Float64Array,
    inIm: Float64Array,
    inOff: number,
    stride: number,
    outRe: Float64Array,
    outIm: Float64Array,
    outOff: number,
    fi: number,
  ): void {
    if (n === 1) {
      outRe[outOff] = inRe[inOff]
      outIm[outOff] = inIm[inOff]
      return
    }
    const p = this.factors[fi]
    const m = n / p
    for (let q = 0; q < p; q++) {
      this.rec(m, inRe, inIm, inOff + q * stride, stride * p, outRe, outIm, outOff + q * m, fi + 1)
    }
    // Combine p sub-transforms of length m: X[k + r*m] = sum_q W_n^{q(k+rm)} Y_q[k]
    const N = this.n
    const step = N / n // twiddle index scale: W_n^j = W_N^{j*step}
    const tRe = this.tRe
    const tIm = this.tIm
    for (let k = 0; k < m; k++) {
      for (let q = 0; q < p; q++) {
        tRe[q] = outRe[outOff + q * m + k]
        tIm[q] = outIm[outOff + q * m + k]
      }
      for (let r = 0; r < p; r++) {
        const idx = k + r * m
        let sr = 0
        let si = 0
        for (let q = 0; q < p; q++) {
          const w = ((q * idx) % n) * step
          const c = this.cos[w]
          const s = this.sin[w]
          sr += tRe[q] * c - tIm[q] * s
          si += tRe[q] * s + tIm[q] * c
        }
        outRe[outOff + idx] = sr
        outIm[outOff + idx] = si
      }
    }
  }
}

function factorize(n: number): number[] {
  const out: number[] = []
  let m = n
  for (const p of [4, 2, 3, 5]) {
    while (m % p === 0) {
      out.push(p)
      m /= p
    }
  }
  for (let p = 7; m > 1; p += 2) {
    while (m % p === 0) {
      out.push(p)
      m /= p
    }
  }
  return out
}
