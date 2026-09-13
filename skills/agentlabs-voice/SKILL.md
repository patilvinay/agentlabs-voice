---
name: claude-voice
description: Operate the claude-voice setup — speech out, dictation, per-session voices, and the browser view of a session. Use when the user asks about hearing replies, dictating, changing the voice, viewing a session or its files in the browser, or when any of the prefix keys (v V p y Space n N m e w) misbehave.
---

# claude-voice

Speech and reading for Claude Code, driven from tmux. Installed by
`./install.sh` from this repo; every command lives in `~/.local/bin` and every
hook in `~/.claude/hooks`.

## Keys (all after the tmux prefix)

| key | does |
|-----|------|
| `v` / `V` | speak the last reply / stop |
| `p` | resume an interrupted reply, from the sentence it was cut in |
| `y` | pick this session's voice |
| `Space` (or `n`) | dictate with live text; `N` dictates and sends |
| `C-Space` | tmux `next-layout`, displaced by `Space` |
| `m` / `e` | dictate offline via whisper / and send |
| `w` | this session in the browser; `W` is tmux's choose-tree |

There are no terminal renderers any more. Floating frogmouth panes, glow and
chafa were removed: the browser shows the same content with real SVG,
selectable text and proper tables, and one renderer is easier to trust than
two.

## The browser view

`prefix w` opens `http://127.0.0.1:7677/s/<session-id>`. One shared md-server
serves every session; the page polls `/api/tick`, so pressing the key again —
or in another session — moves that same tab rather than opening a new one.
wmctrl raises it.

Its sidebar carries the session's three stages, the live panel, the demos, the
markdown in the pane's working directory, and every tracked file of the repo
around it. Source files are highlighted with pygments; markdown gets GFM
tables, mermaid and inline SVG.

| what | where |
|------|-------|
| settings | `~/.claude/hooks/tts.conf` (holds the API key; mode 600, gitignored) |
| this session's voice | `~/.claude/scratch/<session-id>/.voice` |
| the live panel | `~/.claude/wave/claude-view.md` |
| runtime + logs | `/run/user/<uid>/claude-tts-<uid>/debug.log` |

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
- **Stale pane mappings.** A pane keeps its `pane-N.transcript` after Claude
  moves elsewhere, so `session-dir` prefers a pane currently running `claude`.

## Writing replies for it

End a substantive reply with a `<voice>` block: plain prose, no markdown, code,
paths or URLs, stating the outcome rather than the process. Without one the
hook reads the entire message aloud, tables included.

Use `<view>` for the panel — see the `session-scratchpad` skill.
