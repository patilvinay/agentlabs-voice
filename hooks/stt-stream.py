#!/usr/bin/env python3
"""Stream microphone audio to Deepgram and emit live transcripts.

Reads raw 16 kHz mono s16le PCM on stdin (what `arecord -f S16_LE -r 16000 -c 1`
writes), rewrites the running transcript to --live on every update so a display
pane can show it, and prints the finished text to stdout when the stream ends.
"""
import argparse
import asyncio
import json
import os
import socket
import sys
import threading
import time

import urllib.parse

import websockets

BASE = (
    "wss://api.deepgram.com/v1/listen"
    "?punctuate=true&smart_format=true&interim_results=true"
    "&encoding=linear16&sample_rate=16000&channels=1"
)


def build_url(model: str, lang: str, keyterms: list[str]) -> str:
    """Compose the listen URL.

    Two things matter more than the model choice:

    language — asking for the wrong dialect costs accuracy. nova-3 accepts
    en, en-US, en-AU, en-GB, en-IN, en-NZ; "en" is the safe generic. Set
    CC_STT_LANG to your own dialect (en-IN for Indian English) rather than
    leaving a US default in place.

    keyterm — nova-3 boosts up to 100 supplied terms, which is what stops
    proper nouns and jargon being guessed at phonetically ("cloud code" for
    "Claude Code"). Repeatable parameter, plain terms only, no weights, and
    capped at 500 tokens per request.
    """
    url = BASE + f"&model={urllib.parse.quote(model)}&language={urllib.parse.quote(lang)}"
    for t in keyterms:
        t = t.strip()
        if t:
            url += "&keyterm=" + urllib.parse.quote(t)
    return url


def load_keyterms() -> list[str]:
    """Keyterms from CC_STT_KEYTERMS (comma separated) plus an optional file.

    A file is easier to live with than an ever-growing environment variable:
    one term per line, blank lines and # comments ignored.
    """
    terms: list[str] = []
    env = os.environ.get("CC_STT_KEYTERMS", "")
    terms += [t for t in env.split(",") if t.strip()]
    path = os.environ.get("CC_STT_KEYTERM_FILE",
                          os.path.expanduser("~/.claude/hooks/keyterms.txt"))
    try:
        with open(path) as fh:
            for line in fh:
                line = line.split("#", 1)[0].strip()
                if line:
                    terms.append(line)
    except OSError:
        pass
    # Deepgram caps keyterms per request; keep the first 100 and let the rest go
    # rather than having the whole connection rejected.
    return terms[:100]


async def resolve(host: str) -> str | None:
    """The host's IPv4 address, hedged: a lookup through this machine's resolver
    sometimes gets no answer and waits the 5 s timeout (seen 2026-11-03: 5.02 s,
    10.02 s), so a fresh lookup starts every 0.4 s and the first answer wins.
    None lets websockets resolve it itself."""
    loop = asyncio.get_running_loop()
    tries: list[asyncio.Future] = []
    for _ in range(5):
        tries.append(asyncio.ensure_future(loop.getaddrinfo(host, 443, family=socket.AF_INET, type=socket.SOCK_STREAM)))
        done, _ = await asyncio.wait(tries, timeout=0.4, return_when=asyncio.FIRST_COMPLETED)
        for f in done:
            if not f.exception() and f.result():
                for t in tries:
                    t.cancel()
                return f.result()[0][4][0]
    done, _ = await asyncio.wait(tries, timeout=10, return_when=asyncio.FIRST_COMPLETED)
    for f in done:
        if not f.exception() and f.result():
            return f.result()[0][4][0]
    return None


async def run(args, key: str) -> int:
    finals: list[str] = []
    interim = ""

    def write(path: str, text: str) -> None:
        try:
            tmp = path + ".tmp"
            with open(tmp, "w") as fh:
                fh.write(text)
            os.replace(tmp, path)
        except OSError:
            pass

    def paint() -> None:
        # Settled and in-flight text go to separate files so the display can
        # show which words are final and which are still being revised.
        write(args.live, " ".join(finals))
        write(args.live + ".partial", interim)

    # Read the mic from the start, into memory, while the socket connects. The pipe
    # from arecord holds only ~2 s of audio; a slow connect (a DNS lookup took 10 s)
    # filled it, arecord stalled, and the first words were lost.
    loop = asyncio.get_running_loop()
    audio: asyncio.Queue = asyncio.Queue()

    def reader() -> None:
        while True:
            chunk = sys.stdin.buffer.read(3200)
            loop.call_soon_threadsafe(audio.put_nowait, chunk)
            if not chunk:
                return

    threading.Thread(target=reader, daemon=True).start()

    url = build_url(args.model, args.language, load_keyterms())
    headers = {"Authorization": f"Token {key}"}
    host = urllib.parse.urlsplit(url).hostname
    heard: list[bytes] = []      # every chunk so far, replayed after a reconnect
    ended = False

    async def session() -> None:
        nonlocal interim, ended
        t0 = time.monotonic()
        ip = await resolve(host)
        t1 = time.monotonic()
        # Connect to the address found, still checking the certificate against the name.
        extra = {"host": ip, "port": 443, "server_hostname": host} if ip else {}
        try:
            ws = await websockets.connect(url, additional_headers=headers, open_timeout=6, **extra)
        except TypeError:        # older websockets spells it differently
            ws = await websockets.connect(url, extra_headers=headers, open_timeout=6, **extra)
        # Kept in the caller's stderr file (stt.err / live.err) for "why was it late".
        print(f"dns {t1 - t0:.2f}s, connected in {time.monotonic() - t0:.2f}s", file=sys.stderr, flush=True)
        finals.clear()
        interim = ""

        async with ws:
            async def send() -> None:
                nonlocal ended
                sent = 0
                while True:
                    while sent < len(heard):
                        await ws.send(heard[sent])
                        sent += 1
                    if ended:
                        break
                    chunk = await audio.get()
                    if chunk:
                        heard.append(chunk)
                    else:
                        ended = True
                await ws.send(json.dumps({"type": "CloseStream"}))

            async def recv() -> None:
                nonlocal interim
                async for msg in ws:
                    try:
                        data = json.loads(msg)
                    except ValueError:
                        continue
                    alts = data.get("channel", {}).get("alternatives") or []
                    if not alts:
                        continue
                    text = (alts[0].get("transcript") or "").strip()
                    if not text:
                        continue
                    if data.get("is_final"):
                        finals.append(text)
                        interim = ""
                    else:
                        interim = text
                    paint()

            tasks = [asyncio.ensure_future(send()), asyncio.ensure_future(recv())]
            try:
                await asyncio.gather(*tasks)
            finally:
                for t in tasks:
                    t.cancel()

    # The link to Deepgram (San Jose, ~280 ms away) sometimes stalls a handshake or
    # drops a socket mid-stream (2 of 8 runs, 2026-11-03). The audio is all kept, so
    # connect again and replay it from the start; the transcript is rebuilt.
    for attempt in range(1, 5):
        try:
            await session()
            break
        except (OSError, asyncio.TimeoutError, websockets.exceptions.WebSocketException) as e:
            print(f"attempt {attempt} failed: {e}", file=sys.stderr, flush=True)
            if attempt == 4:
                raise

    if interim and interim not in finals:
        finals.append(interim)       # socket closed before this was finalised
    print(" ".join(finals).strip())
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--live", required=True, help="file to rewrite with the running transcript")
    ap.add_argument("--model", default=os.environ.get("CC_STT_ONLINE_MODEL", "nova-3"))
    ap.add_argument("--language", default=os.environ.get("CC_STT_LANG", "en"))
    args = ap.parse_args()

    key = os.environ.get("DEEPGRAM_API_KEY") or os.environ.get("CC_STT_KEY") or ""
    if not key:
        print("stt-stream: no DEEPGRAM_API_KEY set", file=sys.stderr)
        return 2
    try:
        return asyncio.run(run(args, key))
    except KeyboardInterrupt:
        return 130
    except Exception as exc:
        print(f"stt-stream: {exc}", file=sys.stderr)
        return 1


sys.exit(main())
