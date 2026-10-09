# אוזן · Ozen

Hebrew transcription that runs entirely on your phone. Nothing is uploaded.

- **Web** (iPhone Safari, Android Chrome, desktop): https://itayinbarr.github.io/ozen/
- **iPhone app**: coming to the App Store

Powered by [Ozen-v1](https://huggingface.co/itayinbar/Ozen-v1), a 60M-parameter
Hebrew speech recognition model (8.6% WER on ivrit.ai eval-d1).

## Layout

| path | what |
|---|---|
| `web/` | Vite + React web app, deployed to GitHub Pages |
| `ios/` | SwiftUI iPhone app (`xcodegen`), with `OzenCore` inference package |
| `spec/` | Behaviour both apps share: segmenter spec, test vectors, golden transcripts |
| `tools/model/` | Reference pipeline (`reference.py`), fixture generator, pinned model fetch, export tools |

## How it works

Audio is converted to 16 kHz mono and cut into pause-based paragraphs
(`spec/segmenter.md`). Each paragraph becomes a Whisper log-mel, runs through the ONNX
encoder (fp16), and is decoded greedily with the merged ONNX decoder (fp32) and the
Hebrew byte-level BPE. Both apps implement the same steps and are
tested against `tools/model/reference.py`.

## License

Code: MIT. Model and fonts: see `NOTICE`.
