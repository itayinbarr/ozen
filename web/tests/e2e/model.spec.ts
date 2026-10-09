import { expect, test } from '@playwright/test'
import { join } from 'node:path'
import { appUrl, cer, golden, SPEC, startModelServer, type ModelServer } from './helpers.ts'

/**
 * Opt-in (OZEN_E2E_MODEL=1): imports the golden fixtures through the real UI
 * and checks the transcript against spec/golden/golden.json.
 *
 * Model files are served from ~/.cache/ozen/models/82aae03d by a local server
 * passed as ?modelBase= (same bytes: the app checks the pinned SHA-256), unless
 * OZEN_E2E_REAL_DOWNLOAD=1 is set.
 */

test.skip(!process.env.OZEN_E2E_MODEL, 'set OZEN_E2E_MODEL=1 to run the model end-to-end tests')

let server: ModelServer | null = null
test.beforeAll(async () => {
  server = await startModelServer()
})
test.afterAll(() => server?.close())

for (const name of ['sample-he.wav', 'long-he.wav']) {
  test(`transcribes ${name} through the UI`, async ({ page }, info) => {
    test.skip(name === 'long-he.wav' && !process.env.OZEN_E2E_LONG, 'set OZEN_E2E_LONG=1 for the 51 s fixture')
    await page.route('https://gc.zgo.at/**', (r) => r.abort())
    const logs: string[] = []
    page.on('console', (m) => logs.push(`[${m.type()}] ${m.text()}`))
    await page.goto(appUrl(server))
    const t0 = Date.now()
    // Wait for the model to be ready first so the timing below is transcription only.
    await page.waitForFunction(() => document.documentElement.dataset.ozenModel === 'ready', null, { timeout: 10 * 60_000 })
    await page.getByRole('button', { name: 'ייבוא שמע' }).click()
    const tStart = Date.now()
    await page.getByTestId('file-input').setInputFiles(join(SPEC, 'golden', name))
    await expect(page.locator('[data-testid="segments"] .seg-text').first()).toBeVisible({ timeout: 10 * 60_000 })
    await expect(page.getByText('לא נשמר, העתיקו או ייצאו')).toBeVisible()
    const seconds = (Date.now() - tStart) / 1000
    const texts = await page.locator('[data-testid="segments"] .seg-text').allInnerTexts()
    const expected: string[] = golden[name].segments.map((s: { text: string }) => s.text)
    const backend = await page.evaluate(() => document.documentElement.dataset.ozenBackend ?? 'unknown')
    const report = `${info.project.name} ${name}: backend=${backend}, ${seconds.toFixed(1)} s from import to transcript (page open ${((tStart - t0) / 1000).toFixed(1)} s before)`
    console.log(report)
    info.annotations.push({ type: 'timing', description: report })
    expect(texts.length).toBe(expected.length)
    for (let i = 0; i < expected.length; i++) {
      const c = cer(expected[i], texts[i])
      if (c > 0) console.log(`  segment ${i} CER ${(c * 100).toFixed(2)}%\n   got: ${texts[i]}\n   exp: ${expected[i]}`)
      expect(c).toBeLessThanOrEqual(0.02)
    }
    console.log(logs.filter((l) => /\[ozen\]|\[error\]/.test(l)).join('\n'))
  })
}

for (const name of ['long-he.opus', 'long-he.m4a', 'sample-he.mp3', 'sample-he.ogg']) {
  test(`decodes and transcribes ${name} (lossy)`, async ({ page }) => {
    test.skip(!process.env.OZEN_E2E_FORMATS, 'set OZEN_E2E_FORMATS=1 for the container/codec matrix')
    await page.route('https://gc.zgo.at/**', (r) => r.abort())
    await page.goto(appUrl(server))
    await page.waitForFunction(() => document.documentElement.dataset.ozenModel === 'ready', null, { timeout: 10 * 60_000 })
    await page.getByRole('button', { name: 'ייבוא שמע' }).click()
    await page.getByTestId('file-input').setInputFiles(join(SPEC, 'golden', name))
    await expect(page.getByText(name)).toBeVisible() // source chip on the processing screen
    await expect(page.locator('[data-testid="segments"] .seg-text').first()).toBeVisible({ timeout: 10 * 60_000 })
    const got = (await page.locator('[data-testid="segments"] .seg-text').allInnerTexts()).join(' ')
    const ref = golden[name.replace(/\.\w+$/, '.wav')].segments.map((s: { text: string }) => s.text).join(' ')
    const c = cer(ref, got)
    console.log(`${name}: CER vs wav golden ${(c * 100).toFixed(2)}%`)
    expect(c).toBeLessThan(0.15)
  })
}

