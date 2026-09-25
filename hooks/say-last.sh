#!/usr/bin/env bash
# Speak Claude's most recent message on demand — the manual trigger, bound to
# a tmux key or run as `!say-last`. Unlike the Stop hook this does not dedupe,
# so pressing it twice deliberately repeats the same message.
#
# Usage: say-last.sh [transcript.jsonl]   (defaults to the newest for $PWD)

. "$(dirname "$0")/speak.sh"

pane="${TMUX_PANE:-}"
if [ "${1:-}" = "--pane" ]; then pane="$2"; shift 2; fi

t="${1:-}"
# Prefer the transcript this pane's own Claude session is writing.
if [ -z "$t" ] && [ -n "$pane" ]; then
  t=$(agent_session_transcript "$pane") || {
    tts_log "say-last: no session for pane $pane"
    tmux display-message "say-last: no agent session for this pane" 2>/dev/null
    echo "say-last: no session found for pane $pane" >&2; exit 1;
  }
fi
# Fall back to the newest session in this directory.
[ -z "$t" ] && t=$(agent_newest_transcript "$PWD" 2>/dev/null)
[ -n "$t" ] && [ -f "$t" ] || { echo "say-last: no transcript found" >&2; exit 1; }

# Name the session for the voice lookup: TMUX_PANE is empty under run-shell,
# so without this the per-session voice silently falls back to the default.
export CC_TTS_TRANSCRIPT="$t"
export CC_TTS_PANE="$pane"

message=$(agent_latest_message "$t") || { echo "say-last: no completed reply yet" >&2; exit 0; }
text=$(printf '%s' "$message" | jq -r '.text' | tts_resolve)

tts_log "say-last pane=${pane:-none} src=$(basename "$t") chars=${#text}"
case "$text" in ''|' ') echo "say-last: nothing to speak" >&2; exit 0 ;; esac
tts_speak_now "$text"
