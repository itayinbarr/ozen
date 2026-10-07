/**
 * Renders the home-screen icons (orange ear on #e2e8ce) into public/icons with
 * Playwright's Chromium. Run once after changing the artwork: node scripts/icons.ts
 */
import { chromium } from '@playwright/test'
import { resolve } from 'node:path'

const EAR = `<path d="M30 40C30 22 44 12 56 12C72 12 82 26 82 40C82 54 72 60 66 68C60 76 60 88 50 88C44 88 40 84 40 80"/><path d="M44 42C44 32 50 28 57 28C64 28 68 34 68 40C68 48 60 50 58 56"/>`
const svg = (scale: number) =>
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100%" height="100%"><rect width="100" height="100" fill="#e2e8ce"/><g transform="translate(50 50) scale(${scale}) translate(-56 -50)" fill="none" stroke="#ff7f11" stroke-width="9" stroke-linecap="round" stroke-linejoin="round">${EAR}</g></svg>`

const out = resolve(import.meta.dirname, '../public/icons')
const jobs: Array<[string, number, number]> = [
  ['icon-192.png', 192, 0.78],
  ['icon-512.png', 512, 0.78],
  ['apple-touch-icon.png', 180, 0.74],
  ['maskable-512.png', 512, 0.58],
]
const browser = await chromium.launch()
const page = await browser.newPage()
for (const [name, size, scale] of jobs) {
  await page.setViewportSize({ width: size, height: size })
  await page.setContent(`<html><body style="margin:0">${svg(scale)}</body></html>`)
  await page.screenshot({ path: resolve(out, name), clip: { x: 0, y: 0, width: size, height: size } })
}
await browser.close()
console.log('icons written to', out)
