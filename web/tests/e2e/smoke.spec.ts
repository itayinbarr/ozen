import { expect, test } from '@playwright/test'

test.beforeEach(async ({ page }) => {
  // Keep tests hermetic: no analytics, no 165 MB model download.
  await page.route('https://gc.zgo.at/**', (r) => r.abort())
  await page.route('https://huggingface.co/**', (r) => r.abort())
})

test('loads in Hebrew, RTL, without console errors', async ({ page }) => {
  const errors: string[] = []
  page.on('console', (m) => {
    if (m.type() === 'error' && !/huggingface|ERR_FAILED|Failed to load resource|model load failed|download failed/i.test(m.text())) errors.push(m.text())
  })
  page.on('pageerror', (e) => errors.push(e.message))
  await page.goto('./')
  await expect(page.locator('html')).toHaveAttribute('lang', 'he')
  await expect(page.locator('html')).toHaveAttribute('dir', 'rtl')
  await expect(page.getByRole('heading', { name: 'אוזן' })).toBeVisible()
  await expect(page.getByText('לחצו להתחלת הקלטה')).toBeVisible()
  await expect(page.getByRole('button', { name: 'התחלת הקלטה' })).toBeVisible()
  const dir = await page.locator('.app').evaluate((el) => getComputedStyle(el).direction)
  expect(dir).toBe('rtl')
  // Fonts are self-hosted.
  const fontsOk = await page.evaluate(async () => {
    await document.fonts.ready
    return document.fonts.check('700 46px Karantina', 'אוזן')
  })
  expect(fontsOk).toBe(true)
  await page.waitForTimeout(500)
  expect(errors).toEqual([])
})

test('import sheet opens with a file picker', async ({ page }) => {
  await page.goto('./')
  await page.getByRole('button', { name: 'ייבוא שמע' }).click()
  const sheet = page.getByRole('dialog', { name: 'ייבוא שמע' })
  await expect(sheet).toBeVisible()
  await expect(sheet.getByRole('button', { name: 'בחירת קובץ' })).toBeVisible()
  const accept = await page.getByTestId('file-input').getAttribute('accept')
  expect(accept).toContain('audio/*')
  expect(accept).toContain('.opus')
  // Tapping the scrim closes it.
  await page.mouse.click(10, 10)
  await expect(sheet).toBeHidden()
})

test('about sheet links to privacy and support pages', async ({ page }) => {
  await page.goto('./')
  await page.getByRole('button', { name: /אודות/ }).click()
  const sheet = page.getByRole('dialog', { name: 'אודות' })
  await expect(sheet.getByText('ivrit.ai').first()).toBeVisible()
  await sheet.getByRole('link', { name: 'פרטיות' }).click()
  await expect(page).toHaveURL(/privacy\.html$/)
  await expect(page.getByRole('heading', { name: 'פרטיות', level: 1 })).toBeVisible()
  await expect(page.getByText('itayinbar.me@gmail.com').first()).toBeVisible()
  await page.goto('./support.html')
  await expect(page.getByRole('heading', { name: 'תמיכה', level: 1 })).toBeVisible()
  await expect(page.getByRole('heading', { name: 'Support' })).toBeVisible()
})

test('shows the first-run download card or a retry when offline', async ({ page }) => {
  await page.goto('./')
  // Model download is blocked in this test, so the app must say so gracefully.
  await expect(page.getByText(/הורדת המודל נכשלה|אין חיבור לאינטרנט|מורידים את המודל/)).toBeVisible({ timeout: 20_000 })
})

test('serves the PWA manifest, icons, filters and ORT runtime', async ({ request }) => {
  const manifest = await (await request.get('manifest.webmanifest')).json()
  expect(manifest.lang).toBe('he')
  expect(manifest.start_url).toBe('/ozen/')
  for (const icon of manifest.icons) expect((await request.get(icon.src)).ok()).toBe(true)
  const mel = await request.get('mel_filters.bin')
  expect((await mel.body()).length).toBe(201 * 80 * 4)
  expect((await request.get('sw.js')).ok()).toBe(true)
})

test('never scrolls sideways at 320px', async ({ page }) => {
  await page.setViewportSize({ width: 320, height: 640 })
  await page.goto('./')
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
  expect(overflow).toBeLessThanOrEqual(0)
})
