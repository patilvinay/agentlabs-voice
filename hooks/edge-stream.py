#!/usr/bin/env python3
"""Stream edge-tts audio to stdout as chunks arrive, so playback can start
before synthesis finishes.

Exits 0 once any audio was written, 3 if synthesis yielded nothing (offline,
bad voice) so the caller can fall back to the offline engine.
"""
import asyncio
import sys

import edge_tts


async def main() -> int:
    voice, rate, text = sys.argv[1], sys.argv[2], sys.argv[3]
    out = sys.stdout.buffer
    wrote = False
    try:
        async for chunk in edge_tts.Communicate(text, voice, rate=rate).stream():
            if chunk["type"] == "audio" and chunk.get("data"):
                out.write(chunk["data"])
                out.flush()
                wrote = True
    except Exception as exc:                       # network, auth, bad voice
        print(f"edge-stream: {exc}", file=sys.stderr)
        return 0 if wrote else 3
    return 0 if wrote else 3


try:
    sys.exit(asyncio.run(main()))
except BrokenPipeError:                            # player was killed
    sys.exit(0)
except KeyboardInterrupt:
    sys.exit(130)
