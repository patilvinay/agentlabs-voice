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
| `v` / `V` | speak the last reply / stop |
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

## Where state lives

| what | where |
|------|-------|
| settings | `~/.claude/hooks/tts.conf` (holds the API key; mode 600, gitignored) |
| this session's voice | `~/.claude/scratch/<session-id>/.voice` |
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
- **Stale pane mappings.** A pane keeps its `pane-N.transcript` after the agent
  moves elsewhere, so `session-dir` prefers a pane currently running one.

## Writing replies for it

End a substantive reply with a `<voice>` block: plain prose, no markdown, code,
paths or URLs, stating the outcome rather than the process. Without one the
hook reads the entire message aloud, tables included.

`<view>` blocks belong to the companion project's skill, `agentlabs-ideas`.
