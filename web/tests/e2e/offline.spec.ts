import { expect, test } from '@playwright/test'
import { join } from 'node:path'
import { appUrl, SPEC, startModelServer, type ModelServer } from './helpers.ts'

/**
 * Opt-in (OZEN_E2E_MODEL=1): after one online visit the app must work fully
 * offline: shell from the service worker, model from the Cache API.
 */

test.skip(!process.env.OZEN_E2E_MODEL, 'set OZEN_E2E_MODEL=1 to run the model end-to-end tests')
test.use({ serviceWorkers: 'allow' })

let server: ModelServer | null = null
test.beforeAll(async () => {
  server = await startModelServer()
})
test.afterAll(() => server?.close())

test('works offline after the first visit', async ({ page, context, browserName }) => {
  await page.route('https://gc.zgo.at/**', (r) => r.abort())
  // Playwright's WebKit crashes when ONNX Runtime creates WebGPU sessions a second
  // time in the same process (not reproducible with plain WebGPU calls), so the
  // reload part runs on the WASM backend there.
  const url = appUrl(server, browserName === 'webkit' ? { backend: 'wasm' } : {})
  await page.goto(url)
  await page.waitForFunction(() => document.documentElement.dataset.ozenModel === 'ready', null, { timeout: 10 * 60_000 })
  // Wait until the service worker holds the shell and the runtime we used.
  await page.waitForFunction(
    async () => {
      const keys = await caches.keys()
      const shell = keys.find((k) => k.startsWith('ozen-shell-'))
      if (!shell || !keys.some((k) => k.startsWith('ozen-model-'))) return false
      const c = await caches.open(shell)
      const reqs = await c.keys()
      return reqs.some((r) => r.url.endsWith('.wasm')) && reqs.some((r) => r.url.includes('/assets/main-'))
    },
    null,
    { timeout: 60_000, polling: 500 },
  )

  await context.setOffline(true)
  server?.close()
  await page.goto(url)
  await expect(page.getByRole('heading', { name: 'אוזן' })).toBeVisible()
  await page.waitForFunction(() => document.documentElement.dataset.ozenModel === 'ready', null, { timeout: 120_000 })
  await page.getByRole('button', { name: 'ייבוא שמע' }).click()
  await page.getByTestId('file-input').setInputFiles(join(SPEC, 'golden/sample-he.wav'))
  await expect(page.locator('[data-testid="segments"] .seg-text').first()).toContainText('החברה', { timeout: 5 * 60_000 })
})
