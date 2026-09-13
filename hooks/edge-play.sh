#!/usr/bin/env bash
# Stream synthesis straight into the player: speech starts in under a second
# regardless of message length. Exits 3 when synthesis produced no audio, so
# the caller can fall back to the offline engine.
#
# Records its OWN pid rather than letting the parent guess it: setsid forks
# when it is already a process group leader, which would leave the parent
# holding a dead pid and the player un-killable.
#
# Stamps play.start so an interrupted utterance can be resumed from where it
# stopped. Resume re-synthesises the remaining text rather than seeking this
# audio, because cancelling kills synthesis and the file stops at the cut.
#
# Usage: edge-play.sh <text> <generation-token>
. "$(dirname "$0")/speak.sh"

# Belt and braces: the parent exports the session voice, but this script is
# also runnable on its own, and re-sourcing speak.sh would otherwise reset it.
tts_apply_session_voice

gen="$2"
[ "$(cat "$cc_tts_run/gen" 2>/dev/null)" = "$gen" ] || exit 0
echo $$ > "$cc_tts_run/play.pid"
# Re-check after publishing the pid, closing the window where a cancel could
# land between the first check and the write.
[ "$(cat "$cc_tts_run/gen" 2>/dev/null)" = "$gen" ] || exit 0

# Fresh utterance: resume offsets from the previous one no longer apply.
printf '0' > "$cc_tts_run/resume.base"
# Streaming means audio starts ~CC_TTS_RESUME_LAG after this instant; the
# resume maths subtracts it.
printf '%s' "$CC_TTS_RESUME_LAG" > "$cc_tts_run/play.lag"
date +%s%N > "$cc_tts_run/play.start"

"$CC_TTS_VENV/bin/python" "$(dirname "$0")/edge-stream.py" \
    "$CC_TTS_VOICE_EDGE" "$CC_TTS_RATE_EDGE" "$1" 2>/dev/null \
  | mpg123 -q -
rc="${PIPESTATUS[0]}"
# Finished (or killed): drop the stamp so a later cancel cannot mistake a
# completed utterance for one still in flight.
rm -f "$cc_tts_run/play.start"
exit "$rc"
