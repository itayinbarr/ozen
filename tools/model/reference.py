"""
Reference implementation of Ozen's on-device pipeline, in plain numpy + ONNX Runtime.

The web app (onnxruntime-web) and the iPhone app (onnxruntime-objc) run the same
ONNX files with the same steps. This file is the yardstick both are tested
against: segmenter cut points, log-mel features and transcripts.

    python -I tools/model/reference.py transcribe <audio> [--model DIR]
    python -I tools/model/reference.py golden [--model DIR]     # regenerates spec/golden + spec/*.json

Requires: numpy, onnxruntime, soundfile, librosa (resampling only), transformers (cross-check only).
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
SPEC = ROOT / "spec"
DEFAULT_MODEL = Path.home() / ".cache/ozen/models/82aae03d"

SR = 16000
N_FFT = 400
HOP = 160
N_MELS = 80
N_SAMPLES = 30 * SR
N_FRAMES = 3000
BOS, EOS = 1, 2
MAX_NEW_TOKENS = 220

# ---------------------------------------------------------------- segmenter

FRAME = 480
BRIDGE = 17
PAD = 5
MIN_SPEECH = 7
TARGET_MAX = 667
HARD_MAX = 933
SPLIT_FROM = 500
PARA_GAP = 50
MIN_SEG = 67


def frame_db(x: np.ndarray) -> np.ndarray:
    n = math.ceil(len(x) / FRAME)
    out = np.empty(n, dtype=np.float64)
    x = x.astype(np.float64)
    for i in range(n):
        f = x[i * FRAME : min((i + 1) * FRAME, len(x))]
        out[i] = 10 * math.log10(float(np.mean(f * f)) + 1e-10)
    return out


def segment(x: np.ndarray) -> list[tuple[int, int]]:
    """Paragraph cut points in samples. See spec/segmenter.md."""
    if len(x) == 0:
        return []
    db = frame_db(x)
    n = len(db)
    s = sorted(db)
    noise = s[math.floor(0.1 * (n - 1))]
    peak = s[math.floor(0.95 * (n - 1))]
    if peak < -55:
        return []
    thr = noise + max(6.0, 0.35 * (peak - noise))
    voiced = db > thr

    runs: list[list[int]] = []
    i = 0
    while i < n:
        if voiced[i]:
            j = i
            while j < n and voiced[j]:
                j += 1
            runs.append([i, j])
            i = j
        else:
            i += 1

    bridged: list[list[int]] = []
    for r in runs:
        if bridged and r[0] - bridged[-1][1] < BRIDGE:
            bridged[-1][1] = r[1]
        else:
            bridged.append(r)

    kept = [r for r in bridged if r[1] - r[0] >= MIN_SPEECH]

    padded: list[list[int]] = []
    for r in kept:
        a, b = max(0, r[0] - PAD), min(n, r[1] + PAD)
        if padded and a <= padded[-1][1]:
            padded[-1][1] = max(padded[-1][1], b)
        else:
            padded.append([a, b])

    split: list[list[int]] = []
    for a, b in padded:
        while b - a > HARD_MAX:
            lo, hi = a + SPLIT_FROM, a + HARD_MAX
            k = lo
            for j in range(lo, hi):
                if db[j] < db[k]:
                    k = j
            split.append([a, k])
            a = k
        split.append([a, b])

    paras: list[list[int]] = []
    for r in split:
        if not paras:
            paras.append(list(r))
            continue
        cur = paras[-1]
        if r[0] - cur[1] < PARA_GAP and r[1] - cur[0] <= TARGET_MAX:
            cur[1] = r[1]
        else:
            paras.append(list(r))

    changed = True
    while changed:
        changed = False
        for idx, p in enumerate(paras):
            if p[1] - p[0] >= MIN_SEG:
                continue
            if idx > 0 and p[1] - paras[idx - 1][0] <= HARD_MAX:
                paras[idx - 1][1] = p[1]
                del paras[idx]
                changed = True
                break
            if idx + 1 < len(paras) and paras[idx + 1][1] - p[0] <= HARD_MAX:
                paras[idx + 1][0] = p[0]
                del paras[idx]
                changed = True
                break

    return [(a * FRAME, min(b * FRAME, len(x))) for a, b in paras]


# ---------------------------------------------------------------- features


def mel_filters(model_dir: Path) -> np.ndarray:
    """HF WhisperFeatureExtractor's slaney filterbank, shape (201, 80)."""
    from transformers import WhisperFeatureExtractor

    return WhisperFeatureExtractor.from_pretrained(model_dir).mel_filters.astype(np.float32)


def log_mel(x: np.ndarray, filters: np.ndarray) -> np.ndarray:
    """Whisper log-mel, (80, 3000) float32. Mirrors HF's numpy implementation."""
    audio = np.zeros(N_SAMPLES, dtype=np.float64)
    m = min(len(x), N_SAMPLES)
    audio[:m] = x[:m]
    padded = np.pad(audio, (N_FFT // 2, N_FFT // 2), mode="reflect")
    window = np.hanning(N_FFT + 1)[:-1]
    n_frames = 1 + (len(padded) - N_FFT) // HOP
    frames = np.lib.stride_tricks.as_strided(
        padded, shape=(n_frames, N_FFT), strides=(padded.strides[0] * HOP, padded.strides[0])
    )
    spec = np.fft.rfft(frames * window, axis=1)
    power = (spec.real**2 + spec.imag**2)[:-1]  # drop the last frame -> 3000
    mel = power @ filters.astype(np.float64)  # (3000, 80)
    logs = np.log10(np.maximum(mel, 1e-10))
    logs = np.maximum(logs, logs.max() - 8.0)
    return ((logs + 4.0) / 4.0).T.astype(np.float32)


# ---------------------------------------------------------------- tokenizer


def byte_decoder() -> dict[str, int]:
    """Inverse of GPT-2's bytes_to_unicode."""
    bs = list(range(ord("!"), ord("~") + 1)) + list(range(ord("¡"), ord("¬") + 1)) + list(range(ord("®"), ord("ÿ") + 1))
    cs = bs[:]
    n = 0
    for b in range(256):
        if b not in bs:
            bs.append(b)
            cs.append(256 + n)
            n += 1
    return {chr(c): b for b, c in zip(bs, cs)}


class Tokenizer:
    def __init__(self, model_dir: Path):
        t = json.loads((model_dir / "tokenizer.json").read_text())
        self.inv = {i: tok for tok, i in t["model"]["vocab"].items()}
        self.special = {a["id"] for a in t["added_tokens"]}
        self.bd = byte_decoder()

    def decode(self, ids: list[int]) -> str:
        out = bytearray()
        for i in ids:
            if i in self.special:
                continue
            out.extend(self.bd[ch] for ch in self.inv[i])
        return " ".join(out.decode("utf-8", errors="replace").split())


# ---------------------------------------------------------------- model


class Model:
    def __init__(self, model_dir: Path):
        import onnxruntime as ort

        opts = ort.SessionOptions()
        self.enc = ort.InferenceSession(str(model_dir / "onnx/encoder_model_fp16.onnx"), opts)
        self.dec = ort.InferenceSession(str(model_dir / "onnx/decoder_model_merged.onnx"), opts)
        self.layers = sum(1 for i in self.dec.get_inputs() if i.name.endswith(".decoder.key"))
        self.tok = Tokenizer(model_dir)
        self.filters = mel_filters(model_dir)

    def tokens(self, features: np.ndarray) -> list[int]:
        (hidden,) = self.enc.run(None, {"input_features": features[None]})
        empty = np.zeros((1, 8, 0, 64), dtype=np.float32)
        feed = {"encoder_hidden_states": hidden, "use_cache_branch": np.array([False])}
        for layer in range(self.layers):
            for kind in ("decoder", "encoder"):
                for kv in ("key", "value"):
                    feed[f"past_key_values.{layer}.{kind}.{kv}"] = empty
        ids = [BOS]
        out_names = [o.name for o in self.dec.get_outputs()]
        for step in range(MAX_NEW_TOKENS):
            feed["input_ids"] = np.array([[ids[-1]]], dtype=np.int64)
            res = dict(zip(out_names, self.dec.run(None, feed)))
            nxt = int(np.argmax(res["logits"][0, -1]))
            if nxt == EOS:
                break
            ids.append(nxt)
            for layer in range(self.layers):
                for kv in ("key", "value"):
                    feed[f"past_key_values.{layer}.decoder.{kv}"] = res[f"present.{layer}.decoder.{kv}"]
                    if step == 0:
                        feed[f"past_key_values.{layer}.encoder.{kv}"] = res[f"present.{layer}.encoder.{kv}"]
            feed["use_cache_branch"] = np.array([True])
        return ids[1:]

    def transcribe_window(self, x: np.ndarray) -> str:
        return self.tok.decode(self.tokens(log_mel(x, self.filters)))

    def transcribe(self, x: np.ndarray) -> list[dict]:
        out = []
        for a, b in segment(x):
            text = self.transcribe_window(x[a:b])
            if text and not is_degenerate(text):
                out.append({"start": a, "end": b, "text": text})
        return out


def is_degenerate(text: str) -> bool:
    """Port of free-transcribe's repetition-loop guard."""
    words = text.split()
    if len(words) < 12:
        return False
    for size in range(1, 5):
        if len(words) < size * 6:
            continue
        phrase = words[:size]
        repeats = 0
        for i in range(0, len(words) - size + 1, size):
            if words[i : i + size] == phrase:
                repeats += 1
            else:
                break
        if repeats * size > len(words) * 0.7:
            return True
    counts: dict[str, int] = {}
    for w in words:
        counts[w] = counts.get(w, 0) + 1
    return max(counts.values()) > len(words) * 0.6 and len(words) > 20


# ---------------------------------------------------------------- io


def load_audio(path: Path) -> np.ndarray:
    import librosa

    x, _ = librosa.load(str(path), sr=SR, mono=True)
    return x.astype(np.float32)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["transcribe", "segment"])
    ap.add_argument("audio", type=Path)
    ap.add_argument("--model", type=Path, default=DEFAULT_MODEL)
    a = ap.parse_args()
    x = load_audio(a.audio)
    if a.cmd == "segment":
        print(json.dumps(segment(x)))
        return
    m = Model(a.model)
    for seg in m.transcribe(x):
        print(f"[{seg['start'] / SR:7.2f}] {seg['text']}")


if __name__ == "__main__":
    sys.exit(main())
