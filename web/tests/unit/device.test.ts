import { afterEach, describe, expect, it, vi } from 'vitest'
import { mobileOS, recordingHint } from '../../src/lib/device.ts'

function fakeNavigator(userAgent: string, maxTouchPoints = 0) {
  vi.stubGlobal('navigator', { userAgent, maxTouchPoints })
}

describe('recording hint', () => {
  afterEach(() => vi.unstubAllGlobals())

  it('tells iPhone users to keep the screen on and stay in the browser', () => {
    fakeNavigator('Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1', 5)
    expect(mobileOS()).toBe('ios')
    expect(recordingHint()).toBe('אל תכבו את המסך ואל תצאו מהדפדפן בזמן ההקלטה')
  })
  it('treats an iPad that reports itself as a Mac as iOS', () => {
    fakeNavigator('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15', 5)
    expect(mobileOS()).toBe('ios')
  })
  it('tells Android users the screen can go off but the browser must stay open', () => {
    fakeNavigator('Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 Chrome/130.0 Mobile Safari/537.36', 5)
    expect(mobileOS()).toBe('android')
    expect(recordingHint()).toBe('אפשר לכבות את המסך, רק אל תסגרו את הדפדפן')
  })
  it('says nothing on desktop', () => {
    fakeNavigator('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/130.0 Safari/537.36')
    expect(recordingHint()).toBeNull()
  })
})
