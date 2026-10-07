"""
Generation for grafted models.

Whisper ships its own `generate`, built around multilingual decoding: language
detection, forced decoder ids, timestamp ranges and suppression lists, all
indexing its 51,865-token vocabulary. After grafting a Hebrew vocabulary none of
that applies, and clearing the fields one at a time only moves the failure
somewhere else in that code path.

A grafted model is a plain sequence-to-sequence decoder that starts at <s> and
stops at </s>, so it uses the generic implementation directly. Ungrafted models,
including the Whisper baselines, keep their own.
"""

from __future__ import annotations

import torch
from transformers.generation.utils import GenerationMixin


def is_grafted_whisper(model) -> bool:
    """
    A Whisper whose multilingual configuration has been stripped.

    Identified by its config rather than its class name, because the same model
    arrives as WhisperForConditionalGeneration from transformers and as
    ORTModelForSpeechSeq2Seq from optimum, and both inherit the multilingual
    generate that a grafted model must avoid.
    """
    if getattr(getattr(model, "config", None), "model_type", "") != "whisper":
        return False
    config = getattr(model, "generation_config", None)
    return config is not None and getattr(config, "lang_to_id", None) is None


@torch.no_grad()
def generate(model, **kwargs):
    """Generates with the model's own method, unless it is a grafted Whisper."""
    if is_grafted_whisper(model):
        return GenerationMixin.generate(model, **kwargs)
    return model.generate(**kwargs)
