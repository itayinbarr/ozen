import { expect, test } from '@playwright/test'
import { join } from 'node:path'
import { appUrl, SPEC, startModelServer, type ModelServer } from './helpers.ts'

/**
 * Opt-in (OZEN_E2E_MODEL=1, Chromium only): records from a fake microphone that
 * plays spec/golden/sample-he.wav, with a pause in the middle, then checks the
 * transcript and the mini player.
 */

test.skip(!process.env.OZEN_E2E_MODEL, 'set OZEN_E2E_MODEL=1 to run the model end-to-end tests')

test.use({
  permissions: ['microphone'],
  launchOptions: {
    args: [
      '--use-fake-ui-for-media-stream',
      '--use-fake-device-for-media-stream',
      `--use-file-for-fake-audio-capture=${join(SPEC, 'golden/sample-he.wav')}`,
      '--autoplay-policy=no-user-gesture-required',
      '--enable-unsafe-webgpu',
    ],
  },
})

let server: ModelServer | null = null
test.beforeAll(async () => {
  server = await startModelServer()
})
test.afterAll(() => server?.close())

test('records, pauses, stops and transcribes', async ({ page, browserName }) => {
  test.skip(browserName !== 'chromium', 'fake audio capture is a Chromium feature')
  await page.route('https://gc.zgo.at/**', (r) => r.abort())
  await page.goto(appUrl(server))
  await page.waitForFunction(() => document.documentElement.dataset.ozenModel === 'ready', null, { timeout: 10 * 60_000 })
  await page.getByRole('button', { name: 'התחלת הקלטה' }).click()
  await expect(page.getByText('לחצו לסיום')).toBeVisible()
  await page.waitForTimeout(2000)
  await page.getByRole('button', { name: 'השהיית הקלטה' }).click()
  await expect(page.getByText('מושהה · לחצו לסיום')).toBeVisible()
  await page.waitForTimeout(500)
  await page.getByRole('button', { name: 'המשך הקלטה' }).click()
  await page.waitForTimeout(11_000)
  await page.getByRole('button', { name: 'סיום הקלטה' }).click()
  await expect(page.locator('[data-testid="segments"] .seg-text').first()).toBeVisible({ timeout: 5 * 60_000 })
  const text = (await page.locator('[data-testid="segments"] .seg-text').allInnerTexts()).join(' ')
  console.log('recorded transcript:', text)
  expect(text).toMatch(/החברה|הטכנולוגיה|האתגרים/)
  await expect(page.locator('.tr-title')).toContainText('הקלטה')
  // Tap a paragraph: the mini player appears and plays the recording.
  await page.locator('.seg').first().click()
  await expect(page.locator('.player')).toBeVisible()
  await page.waitForFunction(() => (document.querySelector('audio')?.currentTime ?? 0) > 0.2, null, { timeout: 10_000 })
})
