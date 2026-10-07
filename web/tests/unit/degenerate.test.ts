import { describe, expect, it } from 'vitest'
import { isDegenerate } from '../../src/engine/degenerate.ts'

describe('isDegenerate', () => {
  it('keeps short and normal text', () => {
    expect(isDegenerate('')).toBe(false)
    expect(isDegenerate('כן כן כן')).toBe(false)
    expect(isDegenerate('שלום וברוכים הבאים לפגישת הצוות השבועית. היום נעבור על לוח הזמנים של ההשקה, ונראה מה עוד חסר לנו.')).toBe(false)
  })
  it('flags a single word looping', () => {
    expect(isDegenerate(Array(15).fill('תודה').join(' '))).toBe(true)
  })
  it('flags a short phrase looping', () => {
    expect(isDegenerate(Array(8).fill('אני לא יודע').join(' '))).toBe(true)
  })
  it('needs the loop to cover more than 70% from the start', () => {
    const words = 'אחד שתיים שלוש ארבע חמש שש שבע שמונה'.split(' ')
    expect(isDegenerate([...words, ...Array(6).fill('כן')].join(' '))).toBe(false)
  })
  it('flags one word dominating a long output', () => {
    const text = ['התחלה', 'של', ...Array(20).fill('לא'), 'סוף'].join(' ')
    expect(isDegenerate(text)).toBe(true)
  })
  it('does not flag a dominant word in output of 20 words or fewer', () => {
    const text = ['א', 'ב', ...Array(13).fill('לא'), 'ג'].join(' ')
    // 16 words: no prefix loop, dominance rule needs > 20 words
    expect(isDegenerate(text)).toBe(false)
  })
})
