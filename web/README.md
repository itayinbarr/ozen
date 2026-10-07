# Ozen web

Static Vite + React app served from GitHub Pages at `https://itayinbarr.github.io/ozen/`
(base `/ozen/`). Records or imports audio and transcribes Hebrew entirely in the
browser with ONNX Runtime Web. Nothing is uploaded and nothing is saved except the
model, which is cached in the browser.

```
npm ci
npm run dev            # http://localhost:5173/ozen/
npm run typecheck
npm test               # vitest: segmenter vectors, log-mel vs golden, tokenizer, guards
npm run test:golden    # opt-in: full pipeline on onnxruntime-node vs spec/golden/golden.json
npm run build && npm run preview   # http://localhost:4173/ozen/
npm run test:e2e       # Playwright smoke: WebKit "iPhone 15" + Chromium "Pixel 7"
OZEN_E2E_MODEL=1 npm run test:e2e  # + real transcription, recording (fake mic), offline
```

`test:golden` and the model e2e tests read the model from `~/.cache/ozen/models/82aae03d`
(fill it with `tools/model/fetch-model.sh`). `OZEN_GOLDEN_RUNTIME=web` runs the golden
check on onnxruntime-web (WASM) in Node instead. More e2e switches: `OZEN_E2E_LONG=1`
(51 s fixture), `OZEN_E2E_FORMATS=1` (mp3/m4a/ogg/opus), `OZEN_E2E_QUERY=backend=wasm`,
`OZEN_E2E_REAL_DOWNLOAD=1` (download from Hugging Face instead of the local mirror).

## Layout

| path | what |
|---|---|
| `src/engine/` | DOM-free pipeline shared by the worker and the Node golden test: segmenter (`spec/segmenter.md`), FFT + log-mel, byte-level BPE decoder, repetition guard, greedy merged-decoder loop (`model.ts`), model download/verify/cache (`store.ts`) |
| `src/worker.ts` | Web Worker: picks the backend, loads ONNX Runtime and the sessions, streams paragraphs |
| `src/lib/` | main thread: audio decoding (+ ffmpeg.wasm fallback), recorder, engine client, exporters, analytics |
| `src/ui/` | screens from the design (web mode): home/orb, processing, transcript, sheets |
| `src/sw.js` | offline shell service worker (precache list injected at build) |
| `privacy.html`, `support.html` | static pages (Hebrew + English) |

The engine mirrors `tools/model/reference.py` step for step. Token 8191 is an ordinary
word piece in this vocabulary, so nothing is forced or suppressed: plain argmax until
`</s>` or 220 tokens. Both the Node golden test and the browser e2e reproduce
`golden.json` exactly.

Build-time copies (see `vite.config.ts`): `../spec/mel_filters.bin` → `/ozen/mel_filters.bin`,
and ONNX Runtime's `ort-wasm-simd-threaded{,.asyncify}.{mjs,wasm}` → `/ozen/ort/<version>/`
(self-hosted, no CDN).

## Model loading

The three files are fetched once from the pinned Hugging Face revision with a streaming
reader (byte progress, Range resume), checked against their pinned SHA-256 and only then
stored in the Cache API under `ozen-model-82aae03d`. Later visits read from the cache and
work offline; the service worker keeps the app shell and the ONNX Runtime build in use.
`?modelBase=<url>` downloads from a mirror (used by the e2e tests); the SHA-256 check
still applies and the cache key stays the canonical URL.

## Backend and threading

- **WebGPU** (Chrome/Edge, Android Chrome, Safari 26 / iOS 26) when an adapter with
  `shader-f16` exists — the encoder is fp16. Encoder and decoder both run on the GPU and the
  KV cache stays on the GPU between decoder steps (`preferredOutputLocation: 'gpu-buffer'`).
  A short self-test runs after loading; any failure falls back to WASM (decoder first,
  then everything). A localStorage guard switches to WASM for a day if a previous WebGPU
  init never finished (e.g. the tab crashed in the driver).
- **WASM, single-threaded** everywhere else (e.g. iOS 17/18).

We deliberately do **not** enable cross-origin isolation (needed for multi-threaded WASM).
GitHub Pages cannot send COOP/COEP headers, so it would need `coi-serviceworker`, which
reloads the page on the first visit, fails when service workers are unavailable, and makes
every cross-origin subresource (GoatCounter's script and beacon, the ffmpeg.wasm CDN
fallback) need CORS/CORP. `credentialless` is not supported by Safari. (The model download
itself would survive `require-corp`: Hugging Face answers CORS requests.) The gain is also
limited: threads speed up the WASM encoder ~1.7× (measured with 4 threads in Node), and the
shared-memory threaded build is the one most prone to out-of-memory failures on iOS Safari.
Browsers with WebGPU do not benefit at all. Single-threaded WASM is the robust default.

## Analytics

GoatCounter (`ozen.goatcounter.com`), cookieless. Events: `record-start`, `import-file`,
`model-ready` (sent when the model was downloaded on this visit, i.e. first-run completions),
`transcribe-done` and `transcribe-done-{<1m,1-10m,10m+}`. No content, text or file names.
