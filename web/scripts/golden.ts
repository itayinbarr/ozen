/**
 * Golden end-to-end check (opt-in: `npm run test:golden`).
 *
 * Runs the shared engine (src/engine/*, the same modules the browser worker
 * uses) under onnxruntime-node on spec/golden/{sample,long}-he.wav and compares
 * against spec/golden/golden.json produced by tools/model/reference.py:
 * identical paragraph boundaries and CER <= 1% per paragraph.
 *
 *   OZEN_MODEL_DIR=~/.cache/ozen/models/82aae03d npm run test:golden
 *   OZEN_GOLDEN_RUNTIME=web npm run test:golden   # same check on onnxruntime-web (WASM) in Node
 */

import { readFileSync, existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join, resolve } from 'node:path'
import { createHash } from 'node:crypto'
import { MODEL_FILES } from '../src/engine/constants.ts'
import { parseMelFilters } from '../src/engine/mel.ts'
import { Transcriber, type OrtModule } from '../src/engine/model.ts'
import { Tokenizer } from '../src/engine/tokenizer.ts'
import { parseWav } from '../src/engine/wav.ts'
import { cer } from '../src/lib/cer.ts'

const ROOT = resolve(import.meta.dirname, '..', '..')
const SPEC = join(ROOT, 'spec')
const MODEL_DIR = process.env.OZEN_MODEL_DIR ?? join(homedir(), '.cache/ozen/models/82aae03d')
const RUNTIME = process.env.OZEN_GOLDEN_RUNTIME ?? 'node'

interface GoldenEntry {
  samples: number
  window: string
  segments: Array<{ start: number; end: number; text: string }>
}

async function main() {
  if (!existsSync(join(MODEL_DIR, MODEL_FILES[0].path))) {
    console.error(`model not found in ${MODEL_DIR} (run tools/model/fetch-model.sh)`)
    process.exit(2)
  }
  const files = Object.fromEntries(MODEL_FILES.map((f) => [f.key, readFileSync(join(MODEL_DIR, f.path))]))
  for (const f of MODEL_FILES) {
    const sha = createHash('sha256').update(files[f.key]).digest('hex')
    if (sha !== f.sha256) throw new Error(`${f.path}: sha256 ${sha} != pinned ${f.sha256}`)
  }

  let ort: OrtModule & { InferenceSession: { create(b: Uint8Array, o?: object): Promise<any> } }
  let opts: object = {}
  if (RUNTIME === 'web') {
    ort = (await import('onnxruntime-web')) as any
    ;(ort as any).env.wasm.numThreads = Number(process.env.OZEN_THREADS ?? 1)
    opts = { executionProviders: ['wasm'] }
  } else {
    ort = (await import('onnxruntime-node')) as any
    opts = { executionProviders: ['cpu'], ...(process.env.OZEN_THREADS ? { intraOpNumThreads: Number(process.env.OZEN_THREADS) } : {}) }
  }
  const t0 = performance.now()
  const enc = await ort.InferenceSession.create(new Uint8Array(files.encoder), opts)
  const dec = await ort.InferenceSession.create(new Uint8Array(files.decoder), opts)
  const tok = new Tokenizer(files.tokenizer.toString('utf8'))
  const filters = parseMelFilters(readFileSync(join(SPEC, 'mel_filters.bin')))
  const model = new Transcriber(ort, enc, dec, tok, filters)
  console.log(`runtime=${RUNTIME} sessions ready in ${((performance.now() - t0) / 1000).toFixed(1)}s`)

  const golden: Record<string, GoldenEntry> = JSON.parse(readFileSync(join(SPEC, 'golden/golden.json'), 'utf8'))
  let failures = 0
  for (const [name, g] of Object.entries(golden)) {
    const wav = parseWav(readFileSync(join(SPEC, 'golden', name)))
    if (wav.sampleRate !== 16000) throw new Error(`${name}: expected 16 kHz`)
    const x = wav.samples
    if (x.length !== g.samples) {
      console.log(`FAIL ${name}: ${x.length} samples, golden has ${g.samples}`)
      failures++
    }
    const t = performance.now()
    const segs = await model.transcribe(x)
    const secs = (performance.now() - t) / 1000
    const audioSecs = x.length / 16000
    console.log(`\n${name}: ${audioSecs.toFixed(1)} s audio in ${secs.toFixed(2)} s (${(audioSecs / secs).toFixed(1)}x realtime), ${segs.length} segments`)
    if (segs.length !== g.segments.length) {
      console.log(`  FAIL segment count ${segs.length} != ${g.segments.length}`)
      failures++
    }
    for (let i = 0; i < Math.max(segs.length, g.segments.length); i++) {
      const a = segs[i]
      const b = g.segments[i]
      if (!a || !b) continue
      const bounds = a.start === b.start && a.end === b.end
      const c = cer(b.text, a.text)
      const ok = bounds && c <= 0.01
      if (!ok) failures++
      console.log(`  ${ok ? 'ok  ' : 'FAIL'} [${a.start}-${a.end}]${bounds ? '' : ` != [${b.start}-${b.end}]`} CER ${(c * 100).toFixed(2)}%${a.text === b.text ? ' (exact)' : ''}`)
      if (a.text !== b.text) {
        console.log(`       got:      ${a.text}`)
        console.log(`       expected: ${b.text}`)
      }
    }
    if (name === 'sample-he.wav') {
      const w = await model.transcribeWindow(x.subarray(0, 480000))
      const c = cer(g.window, w)
      console.log(`  ${c <= 0.01 ? 'ok  ' : 'FAIL'} 30 s window CER ${(c * 100).toFixed(2)}%${w === g.window ? ' (exact)' : ''}`)
      if (c > 0.01) failures++
    }
  }
  console.log(failures ? `\n${failures} failure(s)` : '\nall golden checks passed')
  await enc.release?.()
  await dec.release?.()
  process.exitCode = failures ? 1 : 0
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
