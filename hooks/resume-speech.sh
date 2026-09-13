#!/usr/bin/env bash
# Resume the interrupted utterance from where it stopped (tmux: prefix + p).
#
# Speech is stopped by prefix+V, by a new turn, or by a notification cutting in.
# Each of those routes through tts_cancel, which records the position first,
# so this picks the same audio back up a beat before the cut.
#
# With nothing to resume, replays the last utterance from the beginning —
# which is the other thing you want this key for ("say that again").
. "$(dirname "$0")/speak.sh"

[ "${1:-}" = "--pane" ] && { export CC_TTS_PANE="$2"; shift 2; }
tts_apply_session_voice || true
tts_recall_voice        # resuming must not change voice mid-message

tts_cancel          # stop current audio AND record where it got to
tts_resume || exit 1
