# Changelog

Releases are git tags `vMAJOR.MINOR.PATCH` on `main`, each with a GitHub release
carrying the section below. PATCH for fixes, MINOR for new features, MAJOR for
changes that break keys, settings or files someone relies on.

## v0.1.1 — 2026-11-03

- Dictation uses Deepgram's India region (`api.in.deepgram.com`) by default; `CC_STT_HOST`
  picks another. From here the transcript keeps pace with speech (median lag 0.0 s) where
  the US host trailed 3-6 s.
- Fix: `CC_STT_LANG`, `CC_STT_KEYTERM_FILE`, `CC_STT_ONLINE_MODEL` from `tts.conf` were never
  exported, so live dictation ran as generic English without keyterms. Now exported.
- `stt.err`/`live.err` name the host, language and keyterm count per run.
- Skill: an "Engines and what they cost" section.

## v0.1.0 — 2026-11-03

First tagged release: everything built so far.

**Speech out**
- Replies spoken from their `<voice>` block (never truncated), queued, never interrupting.
- Narration during a turn (`voice-offer`), auto-speak per session (`prefix A`), mute per session (`prefix M`).
- `prefix u` asks the transcript where a session is.

**Dictation**
- Live dictation on Deepgram nova-3 with dialect and keyterm prompting; offline whisper fallback.
- `C-Space` / `S-Space` dictate too.
- Robust on a slow or flaky link: the mic is buffered from the start, the address is
  cached, connects are hedged, a link that goes quiet for 8 s is dropped and the
  audio replayed on a new one; nothing spoken is lost. `stt.err` logs connect time
  and any lag over 2 s.

**Agents**
- Claude and Codex (rollout and registered-transcript fallback), including sessions
  hosted by `claude daemon`; every pane command resolves the shell beside an agent.
