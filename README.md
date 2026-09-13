# agentlabs-voice

Speech in and out for terminal coding agents, driven entirely from tmux.
Have a reply read aloud, or dictate a prompt and watch the words land at your
cursor.

Nothing speaks or records unless you press a key.

```
 prefix v      read the last reply aloud     prefix V   stop talking
 prefix p      resume where it stopped       prefix y   pick this session's voice
 prefix Space  dictate, with live text       prefix N   dictate and send
 prefix m      dictate offline (whisper)     prefix e   dictate offline and send
```

## Install

```bash
git clone https://github.com/patilvinay/agentlabs-voice && cd agentlabs-voice && ./install.sh
```

Then restart your agent so it picks up the hooks, and **run it**:

```bash
tmux            # then press  prefix v  after any reply
```

The installer is idempotent — re-run it after every pull.

It installs the system packages, a Python venv at `~/.venvs/tts`, the hooks,
the commands, the tmux bindings and one skill. Flags: `--no-sudo` (report
missing packages instead of installing), `--no-stt` (skip the offline whisper
model, ~150 MB), `--no-skills`.

## Using it

**Speech out works immediately** — press `prefix v` after any reply. No key,
no account.

**Offline dictation** (`prefix m`) also needs nothing: a local whisper model,
no network, nothing leaves the machine.

**Live dictation** (`prefix Space`) is the one thing that needs a key — see
below.

## Third-party services

Two, both optional, both off unless you use the feature:

| service | used by | what leaves the machine |
|---------|---------|-------------------------|
| **Microsoft Edge TTS** | speech out, `edge` engine | the text to be spoken |
| **Deepgram** | live dictation, `prefix Space` / `N` | your microphone audio |

Neither is required:

- Set `CC_TTS_ENGINE=spd` for a fully offline voice (espeak-ng). It is
  robotic, and it is local. Edge is the default because it sounds far better;
  it falls back to espeak automatically if it cannot reach the network.
- Use `prefix m` for fully offline dictation. `prefix Space` simply will not
  work without a Deepgram key, and says so.

For live dictation, get a free key at
[console.deepgram.com](https://console.deepgram.com) and put it in
`~/.claude/hooks/tts.conf`:

```bash
DEEPGRAM_API_KEY="${DEEPGRAM_API_KEY:-your_key_here}"
```

That file is created `0600` and is `.gitignore`d. Only `tts.conf.example`,
with an empty key, is in the repo.

## Agent support

| agent | status |
|-------|--------|
| **Claude Code** | implemented and tested |
| **Codex CLI** | adapter included, **not yet verified** — no Codex on the machine this was built on |

Everything agent-specific lives in `lib/agent.sh`: where transcripts are kept
and how a session is named. Nothing else in the project names an agent, so
adding or fixing one is a single file.

## Voices

Speech out uses whatever voice you pick per session with `prefix y`, stored
beside that session so several sessions can sound different. Without a choice
it uses `CC_TTS_VOICE_EDGE` from `tts.conf`.

## Requirements

Linux with ALSA and tmux ≥ 3.0, Python 3.10+. Built and tested on Ubuntu 24.04
with tmux 3.4. Package installation assumes `apt`; elsewhere the installer
lists what is missing and everything else still works.

macOS is not supported as-is: `arecord`/`aplay` and `spd-say` would need
replacing with `sox`/`afplay` and `say`. The engine layer in `hooks/speak.sh`
is where that would go.

## Uninstall

```bash
./uninstall.sh            # keeps tts.conf and the venv
./uninstall.sh --purge    # removes them too
```

Hooks are matched by path, so anything you added yourself is left alone.

## Companion

[agentlabs-ideas-skill](https://github.com/patilvinay/agentlabs-ideas-skill) —
a per-session scratchpad and a browser view of your session's markdown and
source. Independent; installing both is supported and they share one
`lib/agent.sh`.

## Licence

MIT — see [LICENSE](LICENSE).
