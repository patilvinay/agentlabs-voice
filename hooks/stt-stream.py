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


IP_CACHE = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "stt-stream-ip")


async def address(host: str) -> str | None:
    """The address last found for host, at once, refreshed in the background for
    next time: a lookup through this machine's resolver sometimes stalls 5 s for
    every caller at once (2026-11-03), so even hedged lookups waited. The first
    run, or a stale cache, falls back to resolve()."""
    try:
        cached = json.load(open(IP_CACHE)).get(host)
    except (OSError, ValueError):
        cached = None

    async def refresh() -> str | None:
        ip = await resolve(host)
        if ip:
            try:
                d = json.load(open(IP_CACHE))
            except (OSError, ValueError):
                d = {}
            d[host] = ip
            try:
                with open(IP_CACHE + ".tmp", "w") as fh:
                    json.dump(d, fh)
                os.replace(IP_CACHE + ".tmp", IP_CACHE)
            except OSError:
                pass
        return ip

    if cached:
        asyncio.ensure_future(refresh())
        return cached
    return await refresh()


async def connect(url: str, headers: dict, host: str, ip: str | None):
    """Open the socket, hedged: the ~280 ms link to Deepgram sometimes takes 5 s
    to connect where it usually takes under 1 s, so a second attempt starts at
    1.5 s and a third at 3 s; the first one open wins, the rest are closed."""
    extra = {"host": ip, "port": 443, "server_hostname": host} if ip else {}

    async def one():
        try:
            return await websockets.connect(url, additional_headers=headers, open_timeout=8, **extra)
        except TypeError:        # older websockets spells it differently
            return await websockets.connect(url, extra_headers=headers, open_timeout=8, **extra)

    tries: list[asyncio.Future] = []
    error: BaseException | None = None
    for wait in (1.5, 1.5, 8):
        tries.append(asyncio.ensure_future(one()))
        deadline = time.monotonic() + wait
        while tries and time.monotonic() < deadline:
            done, _ = await asyncio.wait(tries, timeout=deadline - time.monotonic(), return_when=asyncio.FIRST_COMPLETED)
            for f in done:
                tries.remove(f)
                if f.exception():
                    error = f.exception()
                    continue
                for t in tries:      # the losers: close if they open, else cancel
                    t.add_done_callback(lambda x: x.cancelled() or x.exception() or asyncio.ensure_future(x.result().close()))
                    t.cancel()
                return f.result()
    raise error or asyncio.TimeoutError("could not connect")


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
        ip = await address(host)
        t1 = time.monotonic()
        # Connect to the address found, still checking the certificate against the name.
        ws = await connect(url, headers, host, ip)
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
                while True:
                    # Deepgram answers every second or so, silence included. A socket
                    # that goes quiet for 8 s has stalled (seen 2026-11-03: send stuck,
                    # nothing back, no error): raise, and the caller reconnects and replays.
                    try:
                        msg = await asyncio.wait_for(ws.recv(), timeout=8)
                    except websockets.exceptions.ConnectionClosedOK:
                        return
                    try:
                        data = json.loads(msg)
                    except ValueError:
                        continue
                    alts = data.get("channel", {}).get("alternatives") or []
                    if not alts:
                        continue
                    # How far the transcript trails the mic: seconds recorded so far
                    # (3200 bytes = 0.1 s) minus the end of the audio this result covers.
                    # Logged when it passes 2 s, to tell network stalls from Deepgram.
                    behind = len(heard) * 0.1 - (data.get("start", 0) + data.get("duration", 0))
                    if behind > 2 and not ended:
                        print(f"lag {behind:.1f}s at {len(heard) * 0.1:.1f}s", file=sys.stderr, flush=True)
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
            except BaseException:
                # A dead link: drop it now; a polite close would wait 10 s for an
                # answer that won't come before the reconnect can start.
                ws.transport.abort()
                raise
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
            print(f"attempt {attempt} failed: {e!r}", file=sys.stderr, flush=True)
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
