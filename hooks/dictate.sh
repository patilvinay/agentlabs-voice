#!/usr/bin/env bash
# Toggle dictation. First press starts recording, second press stops,
# transcribes locally, and types the text into the pane at the cursor.
#
#   dictate.sh --pane %6            insert text only
#   dictate.sh --pane %6 --enter    insert, then submit
. "$(dirname "$0")/speak.sh"

wav="$cc_tts_run/dictate.wav"
pidf="$cc_tts_run/dictate.pid"
modef="$cc_tts_run/dictate.mode"
panef="$cc_tts_run/dictate.pane"

pane=""; enter=0
while [ $# -gt 0 ]; do
  case "$1" in
    --pane)  pane="$2"; shift 2 ;;
    --enter) enter=1; shift ;;
    *)       shift ;;
  esac
done
msg() { tmux display-message "$*" 2>/dev/null; }

if [ -f "$pidf" ]; then
  # ---- second press: stop, transcribe, type ----
  p=$(cat "$pidf"); rm -f "$pidf"
  kill -INT "$p" 2>/dev/null
  # Let arecord finalise the wav header before reading it.
  for _ in $(seq 1 25); do kill -0 "$p" 2>/dev/null || break; sleep 0.1; done

  # The stopping press may be a different key, so use the mode recorded at start.
  pane=$(cat "$panef" 2>/dev/null); enter=$(cat "$modef" 2>/dev/null)
  msg "transcribing..."

  text=$(CC_STT_MODEL="${CC_STT_MODEL:-base.en}" \
         "$CC_TTS_VENV/bin/python" "$cc_tts_hooks/stt.py" "$wav" 2>/dev/null \
         | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')

  tts_log "dictate pane=$pane enter=$enter chars=${#text}"
  [ -n "$text" ] || { msg "dictation: nothing heard"; exit 0; }

  tmux send-keys -t "$pane" -l "$text"
  [ "$enter" = 1 ] && tmux send-keys -t "$pane" Enter
  msg "typed: $(printf '%.60s' "$text")"
else
  # ---- first press: start recording ----
  printf '%s' "$pane" > "$panef"; printf '%s' "$enter" > "$modef"
  rm -f "$wav"
  # setsid so the recorder outlives this run-shell invocation.
  setsid arecord -q -f S16_LE -r 16000 -c 1 "$wav" >/dev/null 2>&1 &
  echo $! > "$pidf"
  msg "recording - press the same key again to stop$([ "$enter" = 1 ] && echo ' (will submit)')"
fi
