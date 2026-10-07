import { createReadStream, existsSync, readFileSync, statSync } from 'node:fs'
import { createServer } from 'node:http'
import type { AddressInfo } from 'node:net'
import { homedir } from 'node:os'
import { join, resolve } from 'node:path'

export const SPEC = resolve(import.meta.dirname, '../../../spec')
export const MODEL_DIR = process.env.OZEN_MODEL_DIR ?? join(homedir(), '.cache/ozen/models/82aae03d')
export const golden = JSON.parse(readFileSync(join(SPEC, 'golden/golden.json'), 'utf8'))

export interface ModelServer {
  base: string
  close: () => void
}

/**
 * Playwright cannot fulfill 80 MB bodies over its protocol (and WebKit cannot
 * route to a redirect), so a tiny CORS + Range server hands the app the cached
 * model via ?modelBase=. Returns null when the model is not cached locally or
 * OZEN_E2E_REAL_DOWNLOAD=1 asks for the real Hugging Face download.
 */
export async function startModelServer(): Promise<ModelServer | null> {
  if (process.env.OZEN_E2E_REAL_DOWNLOAD || !existsSync(join(MODEL_DIR, 'tokenizer.json'))) return null
  const server = createServer((req, res) => {
    const path = join(MODEL_DIR, decodeURIComponent((req.url ?? '/').split('?')[0]))
    if (!path.startsWith(MODEL_DIR) || !existsSync(path)) {
      res.writeHead(404, { 'access-control-allow-origin': '*' }).end()
      return
    }
    const size = statSync(path).size
    const headers: Record<string, string> = {
      'access-control-allow-origin': '*',
      'access-control-allow-headers': '*',
      'access-control-expose-headers': '*',
      'content-type': 'application/octet-stream',
      'accept-ranges': 'bytes',
    }
    if (req.method === 'OPTIONS') {
      res.writeHead(204, headers).end()
      return
    }
    const m = /bytes=(\d+)-/.exec(req.headers.range ?? '')
    const start = m ? Number(m[1]) : 0
    headers['content-length'] = String(size - start)
    if (m) headers['content-range'] = `bytes ${start}-${size - 1}/${size}`
    res.writeHead(m ? 206 : 200, headers)
    createReadStream(path, { start }).pipe(res)
  })
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', () => r()))
  const port = (server.address() as AddressInfo).port
  return { base: `http://127.0.0.1:${port}/`, close: () => server.close() }
}

/** App URL with the model mirror and any OZEN_E2E_QUERY switches (e.g. backend=wasm). */
export function appUrl(server: ModelServer | null, extra: Record<string, string> = {}): string {
  const q = new URLSearchParams(process.env.OZEN_E2E_QUERY ?? '')
  for (const [k, v] of Object.entries(extra)) q.set(k, v)
  if (server) q.set('modelBase', server.base)
  return `./?${q}`
}

export function cer(a: string, b: string): number {
  const r = Array.from(a)
  const h = Array.from(b)
  let prev = Array.from({ length: h.length + 1 }, (_, j) => j)
  for (let i = 1; i <= r.length; i++) {
    const cur = [i]
    for (let j = 1; j <= h.length; j++) cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] === h[j - 1] ? 0 : 1))
    prev = cur
  }
  return prev[h.length] / Math.max(1, r.length)
}
