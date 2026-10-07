"""
Exports a trained model to the ONNX layout transformers.js expects.

The point of this project is a model that runs in a browser, so the export is
not an afterthought: it is verified functionally, by decoding the same audio
through PyTorch and through ONNX Runtime and comparing the text. A numerical
tolerance warning from the exporter says little; identical transcripts say a lot.

    python tools/model/export/export_onnx.py --model runs/tiny-he/best --out artifacts/tiny-he-onnx
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

from generate import generate as run_generate

ROOT = Path(__file__).resolve().parents[2]

# transformers.js loads weights from an onnx/ subdirectory and everything else
# from the repository root.
ONNX_FILES = (
    "encoder_model.onnx",
    "decoder_model_merged.onnx",
    "decoder_model.onnx",
    "decoder_with_past_model.onnx",
)


def export(model_dir: Path, out: Path) -> None:
    staging = out / "_export"
    staging.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        [
            sys.executable, "-m", "optimum.exporters.onnx",
            "--model", str(model_dir),
            "--task", "automatic-speech-recognition-with-past",
            str(staging),
        ],
        capture_output=True,
        text=True,
    )
    if not (staging / "encoder_model.onnx").exists():
        print(result.stdout[-3000:], result.stderr[-3000:])
        raise SystemExit("ONNX export produced no encoder")

    (out / "onnx").mkdir(parents=True, exist_ok=True)
    for name in ONNX_FILES:
        source = staging / name
        if source.exists():
            shutil.move(str(source), out / "onnx" / name)

    for name in ("config.json", "generation_config.json", "preprocessor_config.json"):
        if (staging / name).exists():
            shutil.move(str(staging / name), out / name)
    # The tokenizer travels from the source model, not the exporter.
    for name in ("tokenizer.json", "tokenizer_config.json", "special_tokens_map.json"):
        if (model_dir / name).exists():
            shutil.copy(model_dir / name, out / name)
    from .tokenizer.graft import portable_tokenizer_class

    portable_tokenizer_class(out)

    shutil.rmtree(staging, ignore_errors=True)


def quantise(onnx_dir: Path) -> dict[str, int]:
    """
    Produces the smaller weight variants a browser actually downloads.

    fp32 is what the exporter emits and nobody ships; transformers.js loads
    quantised weights. Both variants are written next to the originals under the
    names transformers.js looks for, and their sizes are returned so the size
    claim is measured rather than projected.

    Note that int8 here comes out *larger* than fp16. Dynamic quantisation only
    touches MatMul weights and leaves everything else at full precision, so on
    this architecture halving every tensor beats quantising some of them. The
    4-bit path transformers.js prefers would be smaller again, but this
    onnxruntime build ships no 4-bit quantiser, so it is not claimed.
    """
    from onnxruntime.quantization import QuantType, quantize_dynamic

    sizes: dict[str, int] = {}
    for name in ("encoder_model", "decoder_model_merged"):
        source = onnx_dir / "onnx" / f"{name}.onnx"
        if not source.exists():
            continue
        sizes[f"{name}.onnx"] = source.stat().st_size

        target = onnx_dir / "onnx" / f"{name}_quantized.onnx"
        try:
            quantize_dynamic(
                model_input=str(source),
                model_output=str(target),
                weight_type=QuantType.QUInt8,
                extra_options={"MatMulConstBOnly": True},
            )
            sizes[target.name] = target.stat().st_size
        except Exception as error:  # noqa: BLE001
            print(f"  int8 quantisation of {name} failed: {type(error).__name__}: {error}")

        try:
            import onnx
            from onnxconverter_common import float16

            half = float16.convert_float_to_float16(
                onnx.load(str(source)), keep_io_types=True, disable_shape_infer=True
            )
            fp16_path = onnx_dir / "onnx" / f"{name}_fp16.onnx"
            onnx.save(half, str(fp16_path))
            sizes[fp16_path.name] = fp16_path.stat().st_size
        except Exception as error:  # noqa: BLE001
            print(f"  fp16 conversion of {name} failed: {type(error).__name__}: {error}")

    return sizes


def browser_download(sizes: dict[str, int]) -> dict[str, float]:
    """What a browser actually fetches: the encoder plus the merged decoder."""
    out = {}
    for suffix, label in (("", "fp32"), ("_fp16", "fp16"), ("_quantized", "int8")):
        encoder = sizes.get(f"encoder_model{suffix}.onnx")
        decoder = sizes.get(f"decoder_model_merged{suffix}.onnx")
        if encoder and decoder:
            out[label] = round((encoder + decoder) / 1e6, 1)
    return out


def verify(model_dir: Path, onnx_dir: Path, audio_split: str, utterances: int) -> dict:
    """Decodes the same audio both ways and compares the transcripts."""
    import torch
    from datasets import load_from_disk
    from optimum.onnxruntime import ORTModelForSpeechSeq2Seq
    from transformers import AutoFeatureExtractor, AutoModelForSpeechSeq2Seq, AutoTokenizer

    from .data.prepare import DATA_ROOT

    dataset = load_from_disk(str(DATA_ROOT / audio_split)).select(range(utterances))
    processor = AutoFeatureExtractor.from_pretrained(str(model_dir))
    tokenizer = AutoTokenizer.from_pretrained(str(model_dir))

    torch_model = AutoModelForSpeechSeq2Seq.from_pretrained(str(model_dir)).eval()
    onnx_model = ORTModelForSpeechSeq2Seq.from_pretrained(str(onnx_dir))

    agree = 0
    examples = []
    for row in dataset:
        inputs = processor(row["audio"]["array"], sampling_rate=16000, return_tensors="pt")
        with torch.no_grad():
            a = tokenizer.decode(
                run_generate(torch_model, **inputs, max_new_tokens=64)[0], skip_special_tokens=True
            )
        b = tokenizer.decode(
            run_generate(onnx_model, **inputs, max_new_tokens=64)[0], skip_special_tokens=True
        )
        agree += a.strip() == b.strip()
        if a.strip() != b.strip() and len(examples) < 3:
            examples.append({"torch": a, "onnx": b})

    return {"utterances": len(dataset), "identical": agree, "differences": examples}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--verify-on", default="fleurs/dev")
    parser.add_argument("--verify-utterances", type=int, default=8)
    parser.add_argument("--skip-verify", action="store_true")
    parser.add_argument("--skip-quantise", action="store_true")
    args = parser.parse_args(argv)

    export(args.model, args.out)
    sizes = {p.name: p.stat().st_size for p in (args.out / "onnx").glob("*.onnx")}
    total = sum(sizes.values())
    print(f"exported to {args.out}")
    for name, size in sorted(sizes.items()):
        print(f"  {name:<34} {size / 1e6:>7.1f} MB")
    print(f"  {'total (fp32)':<34} {total / 1e6:>7.1f} MB")

    if not args.skip_quantise:
        quantised = quantise(args.out)
        downloads = browser_download(quantised)
        if downloads:
            print("\n  what a browser downloads (encoder + merged decoder):")
            for label, mb in downloads.items():
                print(f"    {label:<6} {mb:>7.1f} MB")

    if not args.skip_verify:
        report = verify(args.model, args.out, args.verify_on, args.verify_utterances)
        print(
            f"\nverification: {report['identical']}/{report['utterances']} transcripts "
            f"identical between PyTorch and ONNX Runtime"
        )
        for diff in report["differences"]:
            print(f"  torch: {diff['torch'][:80]}\n  onnx : {diff['onnx'][:80]}")
        (args.out / "export_report.json").write_text(
            json.dumps({"sizes": sizes, **report}, indent=2, ensure_ascii=False), encoding="utf-8"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
