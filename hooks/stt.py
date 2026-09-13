#!/usr/bin/env python3
"""Transcribe a wav file to stdout with faster-whisper (local, offline).

Model is chosen by CC_STT_MODEL; tiny.en/base.en/small.en/medium.en trade
speed for accuracy. Models download once into ~/.cache/huggingface.
"""
import os
import sys

from faster_whisper import WhisperModel

def main() -> int:
    wav = sys.argv[1]
    name = os.environ.get("CC_STT_MODEL", "base.en")
    model = WhisperModel(name, device="cpu", compute_type="int8")
    # vad_filter drops silence, which keeps stray keyboard noise out.
    segments, _ = model.transcribe(wav, beam_size=5, vad_filter=True)
    text = " ".join(s.text.strip() for s in segments).strip()
    print(text)
    return 0

sys.exit(main())
