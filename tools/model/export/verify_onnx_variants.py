#!/usr/bin/env python3
"""
Runs every shippable ONNX dtype combination and compares the transcript.

Written after shipping a broken fp16 decoder. The export had verified the fp32
graphs and merely measured the size of the quantised ones, so the weights a
browser actually downloads were never executed. Loading a graph is not evidence
that it works, and neither is its file size.
"""

from __future__ import annotations

import argparse
import itertools
import shutil
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

SR = 16_000


def combinations(onnx_dir: Path) -> list[tuple[str, str]]:
    def variants(stem: str) -> list[str]:
        found = []
        for suffix in ("", "_fp16", "_quantized"):
            if (onnx_dir / f"{stem}{suffix}.onnx").exists():
                found.append(suffix.lstrip("_") or "fp32")
        return found

    return list(itertools.product(variants("encoder_model"), variants("decoder_model_merged")))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-dir", type=Path, default=Path("artifacts/whisper-base-he-onnx"))
    parser.add_argument("--audio", type=Path,
                        default=Path(__file__).resolve().parents[3] / "spec/golden/sample-he.wav")
    args = parser.parse_args()

    import subprocess

    import torch
    from optimum.onnxruntime import ORTModelForSpeechSeq2Seq
    from transformers import AutoFeatureExtractor, AutoTokenizer

    from generate import generate as run_generate

    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-nostdin", "-i", str(args.audio),
         "-f", "f32le", "-ac", "1", "-ar", str(SR), "-"],
        capture_output=True, check=True,
    ).stdout
    audio = np.frombuffer(raw, dtype=np.float32)[: SR * 20]

    features = AutoFeatureExtractor.from_pretrained(str(args.model_dir))
    tokenizer = AutoTokenizer.from_pretrained(str(args.model_dir))
    inputs = features(audio, sampling_rate=SR, return_tensors="pt", padding="max_length")

    onnx_dir = args.model_dir / "onnx"
    print(f"{'encoder':>10} {'decoder':>10}  {'size':>9}  result")
    reference = None
    ok: list[tuple[str, str, float]] = []

    for enc, dec in combinations(onnx_dir):
        # optimum loads by fixed filenames, so each candidate is staged into a
        # temporary directory under the names it expects.
        stage = Path("/tmp/onnx-variant")
        shutil.rmtree(stage, ignore_errors=True)
        (stage / "onnx").mkdir(parents=True)
        for name in ("config.json", "generation_config.json", "preprocessor_config.json",
                     "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json"):
            if (args.model_dir / name).exists():
                shutil.copy(args.model_dir / name, stage / name)
        enc_file = f"encoder_model{'' if enc == 'fp32' else '_' + enc}.onnx"
        dec_file = f"decoder_model_merged{'' if dec == 'fp32' else '_' + dec}.onnx"
        shutil.copy(onnx_dir / enc_file, stage / "onnx" / "encoder_model.onnx")
        shutil.copy(onnx_dir / dec_file, stage / "onnx" / "decoder_model_merged.onnx")
        size = ((onnx_dir / enc_file).stat().st_size + (onnx_dir / dec_file).stat().st_size) / 1e6

        try:
            model = ORTModelForSpeechSeq2Seq.from_pretrained(str(stage))
            ids = run_generate(model, **inputs, max_new_tokens=80)
            text = tokenizer.decode(ids[0], skip_special_tokens=True).strip()
            if reference is None:
                reference = text
            match = "matches fp32" if text == reference else "DIFFERENT TEXT"
            print(f"{enc:>10} {dec:>10}  {size:>7.1f} MB  {match}")
            if text == reference:
                ok.append((enc, dec, size))
        except Exception as error:  # noqa: BLE001
            print(f"{enc:>10} {dec:>10}  {size:>7.1f} MB  FAILS: {str(error)[:70]}")

    if ok:
        best = min(ok, key=lambda x: x[2])
        print(f"\nsmallest combination that works: encoder {best[0]}, decoder {best[1]}, {best[2]:.1f} MB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
