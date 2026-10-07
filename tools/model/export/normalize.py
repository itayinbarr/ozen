"""
Hebrew text normalisation for evaluation.

This is a faithful reimplementation of the normaliser used by the ivrit.ai
Hebrew transcription leaderboard (`evaluate_model.py` in ivrit-ai/asr-training).
Any deviation makes our WER numbers non-comparable with the published ones,
which is the entire point of measuring them, so `tests/test_normalize.py`
checks it against their published per-utterance results.
"""

from __future__ import annotations

from hebrew import Hebrew
from transformers.models.whisper.english_normalizer import BasicTextNormalizer

# Invisible characters that survive copy-paste and silently change a WER.
_INVISIBLE = (
    "؜"  # Arabic letter mark
    "​‌‍"  # zero-width space, non-joiner, joiner
    "‎‏"  # left-to-right and right-to-left marks
    "‪‫‬‭‮"  # embedding, pop, override
    "⁦⁧⁨⁩"  # isolate controls
    "﻿"  # zero-width no-break space
)
_INVISIBLE_MAP = {ord(c): None for c in _INVISIBLE}


def strip_invisible(text: str) -> str:
    """Removes bidi controls and zero-width characters."""
    return text.translate(_INVISIBLE_MAP)


def strip_niqqud(text: str) -> str:
    """
    Removes Hebrew vowel points.

    This delegates to the `hebrew` package rather than filtering the Unicode
    range by hand, because that is what the leaderboard does. The distinction is
    not cosmetic: `no_niqqud` removes vowel points but leaves cantillation marks
    in place, while a hand-rolled range filter strips both, which changes the
    WER on any text carrying te'amim.
    """
    return Hebrew(text).no_niqqud().string


class HebrewTextNormalizer:
    """Callable normaliser matching the ivrit.ai leaderboard."""

    def __init__(self) -> None:
        self._basic = BasicTextNormalizer()

    def __call__(self, text: str | None) -> str:
        if not text:
            return ""
        text = strip_invisible(text)
        text = strip_niqqud(text)
        text = text.replace('"', "").replace("'", "")
        return self._basic(text)


normalize = HebrewTextNormalizer()
