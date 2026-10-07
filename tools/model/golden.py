"""
Regenerates the shared test fixtures in spec/ that the web and iOS test suites read.

    python -I tools/model/golden.py

Writes:
  spec/golden/long-he.{wav,m4a,opus}  ~90 s Hebrew (macOS "Carmit" TTS) with pauses
  spec/golden/golden.json             reference paragraphs + text per fixture
  spec/golden/sample-he.mel.bin       (80, 3000) float32 LE log-mel of sample-he.wav
  spec/mel_filters.bin                (201, 80) float32 LE slaney filterbank (shipped in both apps)
  spec/segmenter-vectors.json         synthetic signals + expected cut points
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import reference as R  # noqa: E402

GOLDEN = R.SPEC / "golden"

LONG_TEXT = [
    "שלום, וברוכים הבאים לפגישת הצוות השבועית. היום נעבור על לוח הזמנים של ההשקה, ונראה מה עוד חסר לנו.",
    "סיימנו את רוב הבדיקות. נשארו שני באגים קטנים במסך ההגדרות, ואני מעריכה שנסגור אותם עד יום שלישי.",
    "מצוין. ומה לגבי התרגום לאנגלית? קיבלנו את הקבצים אתמול, ואני עובר עליהם היום ושולח הערות מחר בבוקר.",
    "אם הכל מסתדר, אפשר לכוון להשקה ביום ראשון הבא. בואו נקבע פגישה קצרה ביום חמישי ונוודא שאין הפתעות.",
    "דבר אחרון לפני שמסיימים. מי מכין את ההודעה ללקוחות? אני לוקחת את זה, וטיוטה ראשונה תהיה מוכנה עד סוף השבוע.",
    "תודה לכולם. נתראה בשבוע הבא, ובהצלחה עם ההכנות.",
]


def make_long() -> None:
    script = " [[slnc 1800]] ".join(LONG_TEXT)
    with tempfile.TemporaryDirectory() as d:
        aiff = Path(d) / "long.aiff"
        subprocess.run(["say", "-v", "Carmit", "-r", "175", "-o", str(aiff), script], check=True)
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(aiff), "-ac", "1", "-ar", "16000",
                        "-c:a", "pcm_s16le", str(GOLDEN / "long-he.wav")], check=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(GOLDEN / "long-he.wav"), "-c:a", "aac",
                    "-b:a", "64k", str(GOLDEN / "long-he.m4a")], check=True)
    # WhatsApp voice notes are Ogg Opus, mono, 16 kHz.
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(GOLDEN / "long-he.wav"), "-c:a", "libopus",
                    "-b:a", "24k", "-ar", "16000", "-application", "voip", str(GOLDEN / "long-he.opus")], check=True)


# --------------------------------------------------------------- synthetic segmenter vectors


def lcg_noise(n: int, amp: float, seed: int) -> np.ndarray:
    """Deterministic noise every platform can reproduce with uint32 math."""
    out = np.empty(n, dtype=np.float64)
    s = seed & 0xFFFFFFFF
    for i in range(n):
        s = (s * 1664525 + 1013904223) & 0xFFFFFFFF
        out[i] = (s / 4294967296.0 * 2.0 - 1.0) * amp
    return out


def synth(pieces: list[dict], seed: int) -> np.ndarray:
    """
    Concatenates pieces; each is {"n": samples, "tone": amplitude, "hz": frequency}.
    Background noise of amplitude 0.002 is added everywhere. Mirrors
    web/src/engine/synth.ts and OzenCoreTests/Synth.swift.
    """
    total = sum(p["n"] for p in pieces)
    x = lcg_noise(total, 0.002, seed)
    off = 0
    for p in pieces:
        if p.get("tone"):
            t = np.arange(p["n"], dtype=np.float64)
            # A slow 4 Hz envelope makes the "speech" bursty like syllables.
            env = 0.6 + 0.4 * np.sin(2 * np.pi * 4.0 * t / R.SR)
            x[off : off + p["n"]] += p["tone"] * env * np.sin(2 * np.pi * p["hz"] * t / R.SR)
        off += p["n"]
    return x.astype(np.float32)


def sec(s: float) -> int:
    return int(round(s * R.SR))


VECTOR_CASES = {
    "silence": [{"n": sec(5)}],
    "empty": [],
    "one_utterance": [{"n": sec(1)}, {"n": sec(6), "tone": 0.3, "hz": 220}, {"n": sec(1)}],
    "short_pause_bridged": [{"n": sec(0.5)}, {"n": sec(3), "tone": 0.3, "hz": 200}, {"n": sec(0.3)},
                            {"n": sec(3), "tone": 0.3, "hz": 260}, {"n": sec(0.5)}],
    "paragraph_gap": [{"n": sec(0.5)}, {"n": sec(5), "tone": 0.3, "hz": 200}, {"n": sec(2.0)},
                      {"n": sec(5), "tone": 0.3, "hz": 240}, {"n": sec(0.5)}],
    "packed_until_target": [{"n": sec(0.5)}] + [
        p for i in range(6) for p in ({"n": sec(6), "tone": 0.25, "hz": 180 + 20 * i}, {"n": sec(0.8)})
    ],
    "continuous_long": [{"n": sec(0.5)}, {"n": sec(40), "tone": 0.3, "hz": 210}, {"n": sec(0.5)}],
    "short_absorbed": [{"n": sec(0.5)}, {"n": sec(1.0), "tone": 0.3, "hz": 300}, {"n": sec(2.5)},
                       {"n": sec(8), "tone": 0.3, "hz": 220}, {"n": sec(0.5)}],
    "blip_dropped": [{"n": sec(1)}, {"n": sec(0.1), "tone": 0.4, "hz": 900}, {"n": sec(2)},
                     {"n": sec(4), "tone": 0.3, "hz": 220}, {"n": sec(1)}],
    "quiet_speaker": [{"n": sec(0.5)}, {"n": sec(5), "tone": 0.02, "hz": 220}, {"n": sec(1)}],
}


def make_vectors() -> None:
    cases = []
    for i, (name, pieces) in enumerate(VECTOR_CASES.items()):
        seed = 1000 + i
        x = synth(pieces, seed)
        cases.append({"name": name, "seed": seed, "pieces": pieces, "samples": int(len(x)),
                      "expected": [list(p) for p in R.segment(x)]})
    out = {"noiseAmp": 0.002, "envelopeHz": 4.0, "cases": cases}
    (R.SPEC / "segmenter-vectors.json").write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n")
    for c in cases:
        print(f"  {c['name']:22s} {[(round(a / R.SR, 2), round(b / R.SR, 2)) for a, b in c['expected']]}")


def main() -> None:
    GOLDEN.mkdir(parents=True, exist_ok=True)
    model_dir = R.DEFAULT_MODEL
    filters = R.mel_filters(model_dir)
    filters.astype("<f4").tofile(R.SPEC / "mel_filters.bin")

    make_long()
    make_vectors()

    sample = R.load_audio(GOLDEN / "sample-he.wav")
    R.log_mel(sample, filters).astype("<f4").tofile(GOLDEN / "sample-he.mel.bin")

    m = R.Model(model_dir)
    golden = {}
    for name in ["sample-he.wav", "long-he.wav"]:
        x = R.load_audio(GOLDEN / name)
        segs = m.transcribe(x)
        golden[name] = {"samples": int(len(x)), "window": m.transcribe_window(x[: R.N_SAMPLES]),
                        "segments": segs}
        print(name)
        for s in segs:
            print(f"  [{s['start'] / R.SR:6.2f}-{s['end'] / R.SR:6.2f}] {s['text']}")
    (GOLDEN / "golden.json").write_text(json.dumps(golden, ensure_ascii=False, indent=1) + "\n")


if __name__ == "__main__":
    main()
