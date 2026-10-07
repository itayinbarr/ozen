/** Transcript serialisation for copy / .txt / .md / share. Pure string work. */

import { fmt } from './format.ts'

export interface TranscriptDoc {
  title: string
  date: string
  duration: number
  segments: Array<{ start: number; text: string }>
}

export function toText(d: TranscriptDoc): string {
  return `${d.title}\n${d.date} · ${fmt(d.duration)}\n\n` + d.segments.map((g) => `[${fmt(g.start)}] ${g.text}`).join('\n\n') + '\n'
}

export function toMarkdown(d: TranscriptDoc): string {
  return `# ${d.title}\n\n_${d.date} · ${fmt(d.duration)}_\n\n` + d.segments.map((g) => `**${fmt(g.start)}**\n${g.text}`).join('\n\n') + '\n'
}
