---
name: agentlabs-voice
description: Operate agentlabs-voice — speech out, dictation, resume, and per-session voices for a terminal coding agent, driven from tmux. Use when the user asks to hear a reply, to dictate, to change the voice, or when any of the prefix keys (v V p y Space n N m e) misbehaves or stays silent.
---

# agentlabs-voice

Speech in and out for a terminal coding agent, driven from tmux. Installed by
`./install.sh`; commands land in `~/.local/bin`, hooks in `~/.claude/hooks`,
and everything agent-specific is confined to `lib/agent.sh`.

## Keys (all after the tmux prefix)

| key | does |
|-----|------|
| `v` / `V` | speak the last reply / stop and drop the queue |
| `>` | skip the utterance being spoken, play the next |
| `A` | auto-speak on/off, for this session only |
| `p` | resume an interrupted reply, from the sentence it was cut in |
| `y` | pick this session's voice |
| `Space` (or `n`) | dictate with live text; `N` dictates and sends |
| `C-Space` | tmux `next-layout`, displaced by `Space` |
| `m` / `e` | dictate offline via whisper / and send |

## The helper panes create themselves

Nothing has to be set up by hand. Two things split a small pane and clean it up:

- **end of turn**, when `CC_TTS_OFFER=1` — a 7-line pane offering to narrate the
  reply. Idempotent: before splitting it checks whether the pane from the
  previous turn is still open and does nothing if so, so turns never stack.
- **`prefix Space`** — a pane showing live transcription, which closes when you
  stop speaking.

Reading a session's markdown in a browser is a separate project,
[agentlabs-ideas-skill](https://github.com/patilvinay/agentlabs-ideas-skill).

## Narrating during a turn

During a long turn, write a `<voice>` block and then run `voice-offer` as the
next tool call. It reads that block out of the transcript and narrates it the
same way the end of a turn does. Don't wait for it; carry on working.

A turn has up to three beats, and each must say something the others do not:

**Opening — what I understood, and what I am about to do.** Only when the turn
will take real time. Its real job is catching a misheard request: dictation
garbles things, and hearing the task said back wrong costs three seconds to
correct instead of three minutes. Say the task and the shape of the plan, not
a list of steps. Skip it entirely when auto-speak is off — the pane would pop
and grab focus the moment they finished typing, and they are looking at the
screen anyway.

**Middle — something changed.** A finding that redirects the work, a plan that
turned out to be wrong, a blocking question, or a slow thing about to start.
Only when it actually changed; there is nothing to say most of the time.

**Closing — the outcome.** The `<voice>` block at the end of the reply, as
always.

**With auto-speak on, the closing beat is not optional.** Without a `<voice>`
block the hook falls back to reading the whole reply -- lists, tables and all
-- straight into their ears, with no pane to glance at and dismiss. Skipping
it is only safe for a genuine one-liner.

Three a turn is the ceiling and most turns want one. Do not narrate progress
for its own sake — "reading the config now", "running the tests", "that
worked". Narrating every step is how this ends up switched off.

Same rules as the end-of-turn block: plain prose for the ear, no markdown,
code, paths, flags or URLs; the outcome, not the process. Never repeat what an
earlier beat already said.

`voice-offer` exits silently and returns 0 when there is nothing new to say,
when the same text was already narrated, or when the pane is not on screen.
Calling it and hearing nothing is not a failure, so do not retry or debug it.

    voice-offer                 the newest <voice> block
    voice-offer --text "..."    this text instead
    voice-offer --force         ignore the focus gate (testing)

## Auto-speak and the queue

`CC_TTS_AUTO=1` speaks without asking; `prefix A` toggles it per session, in
`<scratch>/<session-id>/.auto`, so watching one agent does not make five of
them talk. With it off, summaries offer a pane instead.

Utterances QUEUE. This replaced the original cancel-on-new behaviour, where
each new utterance killed the one in progress -- fine for one reply per turn,
wrong the moment anything narrates mid-turn.

- `tts_speak` appends; a single drainer under `flock` plays them in order
- each entry carries its own voice, because sessions choose different ones and
  the drainer may reach an entry long after it was queued
- `tts_speak_now` (prefix `v`, permission prompts) jumps the queue and drops
  what is playing; `prefix p` brings that back
- `tts_cancel` alone is a SKIP: the drainer sees its player die and takes the
  next entry. `tts_stop_all` sets the stop flag and clears the queue

## Where state lives

| what | where |
|------|-------|
| settings | `~/.claude/hooks/tts.conf` (holds the API key; mode 600, gitignored) |
| this session's voice | `~/.claude/scratch/<session-id>/.voice` |
| this session's auto-speak | `~/.claude/scratch/<session-id>/.auto` |
| the utterance queue | `/run/user/<uid>/claude-tts-<uid>/queue/` |
| the live panel | `~/.claude/wave/claude-view.md` |
| speech runtime + log | `/run/user/<uid>/claude-tts-<uid>/debug.log` |
| pane → session map | `/run/user/<uid>/agentlabs/` (shared with the companion project) |

## Reading the log first

`debug.log` names the engine and voice on every utterance:

    engine=edge mode=stream voice=en-GB-RyanNeural chars=216

That one line settles most questions — which voice was used, whether it fell
back to the offline engine, whether a turn was skipped.

## Things that have actually gone wrong

- **`TMUX_PANE` is EMPTY** inside `run-shell` bindings *and* `display-popup`.
  Anything that identifies a session from the environment must instead be
  handed the pane: bindings pass `#{pane_id}`, and `tts_session_id` reads
  `CC_TTS_PANE`. Symptoms: a popup that flashes and exits, or the default
  voice being used despite a saved choice.
- **The player is a separate process.** `edge-play.sh` re-sources `speak.sh`,
  so anything set for it must be *exported*, not just assigned.
- **Silence is usually deliberate.** `CC_TTS_ONLY_ACTIVE=1` keeps the Stop hook
  quiet unless that pane's tmux window is selected and a client is attached.
  `prefix v` always speaks.
- **A stale stop flag.** `prefix V` with nothing playing leaves the flag with
  no drainer to consume it, and it would then truncate the next batch after
  one utterance. `tts_enqueue` clears it.
- **Stale pane mappings.** A pane keeps its `pane-N.transcript` after the agent
  moves elsewhere, so `session-dir` prefers a pane currently running one.

## Writing replies for it

End a substantive reply with a `<voice>` block: plain prose, no markdown, code,
paths or URLs, stating the outcome rather than the process. Without one the
hook reads the entire message aloud, tables included.

Mid-turn, write a `<voice>` block and then run `voice-offer`. Worth doing when
the person would otherwise wait without knowing why: before something slow,
after a finding that changes the approach, when a plan turns out to be wrong.
Not worth doing for progress noise -- narrating every step is how someone ends
up turning the whole thing off.

`<view>` blocks belong to the companion project's skill, `agentlabs-ideas`.
