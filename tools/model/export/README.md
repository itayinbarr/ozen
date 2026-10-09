# Model export tools

Carried over from the (retired) training repo so Ozen's ONNX files can be
re-exported and re-verified without it. They need `torch`, `transformers`,
`optimum` and, for `normalize.py`, the `hebrew` package.

- `export_onnx.py`: exports a checkpoint to the transformers.js ONNX layout
  (fp32, fp16, int8) and compares ONNX transcripts against PyTorch.
- `verify_onnx_variants.py`: transcribes with every encoder/decoder dtype mix and
  diffs the text against fp32. Ozen ships the fp16 encoder + fp32 merged decoder;
  the fp16 decoder does not load, and int8 changes the transcript.
- `generate.py`: generic `generate` for a Whisper with a grafted Hebrew vocabulary.
- `normalize.py`: Hebrew normaliser matching the ivrit.ai leaderboard, for WER.

Lesson worth keeping: a graph that loads is not a graph that works. Test the
exact dtype files you ship (`tools/model/golden.py` does this for the apps).
