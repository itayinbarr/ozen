# Segmenter

Cuts 16 kHz mono audio into paragraphs at pauses. Each paragraph is transcribed
on its own (padded to Whisper's 30 s window) and shown with its start time, so
the segmenter decides both what the model sees and how the transcript reads.

The web (`web/src/engine/segmenter.ts`), iOS (`ios/OzenCore/Sources/OzenCore/Segmenter.swift`)
and reference (`tools/model/reference.py`) implementations must agree exactly on
`segmenter-vectors.json`. Compute energies in 64-bit floats.

## Constants

| name            | value | meaning                                          |
|-----------------|-------|--------------------------------------------------|
| `FRAME`         | 480   | samples per frame (30 ms)                        |
| `BRIDGE`        | 17    | frames; silences shorter than this are bridged (≈500 ms) |
| `PAD`           | 5     | frames of padding added to each side of speech (150 ms) |
| `MIN_SPEECH`    | 7     | frames; voiced runs shorter than this are dropped (210 ms) |
| `TARGET_MAX`    | 667   | frames; a paragraph grows by merging only up to this (≈20 s) |
| `HARD_MAX`      | 933   | frames; nothing longer is ever sent to the model (≈28 s) |
| `SPLIT_FROM`    | 500   | frames; earliest cut point inside an over-long region (15 s) |
| `PARA_GAP`      | 50    | frames; a pause this long always starts a new paragraph (1.5 s) |
| `MIN_SEG`       | 67    | frames; shorter paragraphs are merged into a neighbour (≈2 s) |

## Algorithm

1. **Frames.** `n = ceil(N / FRAME)`. Frame `i` covers samples
   `[i*FRAME, min((i+1)*FRAME, N))`. Its energy is
   `db[i] = 10 * log10(mean(x²) + 1e-10)`. If `N == 0` return `[]`.
2. **Threshold.** Sort a copy of `db`. `noise = sorted[floor(0.1*(n-1))]`,
   `peak = sorted[floor(0.95*(n-1))]`. If `peak < -55` return `[]` (silence).
   `thr = noise + max(6, 0.35 * (peak - noise))`. Frame `i` is voiced when `db[i] > thr`.
3. **Runs.** Collect maximal runs of voiced frames as half-open `[s, e)`.
4. **Bridge.** Walking left to right, merge a run into the previous one when
   `run.s - prev.e < BRIDGE`.
5. **Drop blips.** Remove runs with `e - s < MIN_SPEECH`.
6. **Pad.** `s = max(0, s - PAD)`, `e = min(n, e + PAD)`; then merge any runs
   that now touch or overlap (`run.s <= prev.e`).
7. **Split long.** While a run has `e - s > HARD_MAX`: find the frame `k` in
   `[s + SPLIT_FROM, s + HARD_MAX)` with the lowest `db[k]` (earliest on ties),
   emit `[s, k)`, continue with `[k, e)`.
8. **Pack.** Walking left to right with `cur` = first run: for the next run `r`,
   if `r.s - cur.e < PARA_GAP` and `r.e - cur.s <= TARGET_MAX`, set `cur.e = r.e`;
   otherwise emit `cur` and set `cur = r`. Emit the last `cur`.
9. **Absorb short.** Repeat until nothing changes: take the first paragraph `p`
   with `p.e - p.s < MIN_SEG` that can merge with a neighbour. Prefer the previous
   paragraph `q` if `p.e - q.s <= HARD_MAX` (result `[q.s, p.e)`), else the next
   paragraph `r` if `r.e - p.s <= HARD_MAX` (result `[p.s, r.e)`). A short
   paragraph that cannot merge stays as it is.
10. **Output.** Each paragraph as samples `[s*FRAME, min(e*FRAME, N))`.

## Why these numbers

- Pauses under half a second are breaths between words; cutting there would split
  sentences and hurt accuracy, so they are bridged.
- Paragraphs aim for ≤ 20 s because that reads well on a phone and keeps the
  decoder far from its 448-token limit; 28 s is a hard ceiling under Whisper's 30 s.
- An over-long stretch of continuous speech is cut at its quietest 30 ms frame
  between 15 and 28 s, which is almost always a gap between words, so no
  overlap or seam de-duplication is needed.
