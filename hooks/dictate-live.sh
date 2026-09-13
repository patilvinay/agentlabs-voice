#!/usr/bin/env bash
# Live dictation. First press opens a small pane that shows words as you speak;
# second press closes it and types the finished text at your cursor.
#
#   dictate-live.sh --pane %6            insert text only
#   dictate-live.sh --pane %6 --enter    insert, then submit
. "$(dirname "$0")/speak.sh"

live="$cc_tts_run/live.txt"
final="$cc_tts_run/live.final"
fifo="$cc_tts_run/live.fifo"
recpid="$cc_tts_run/live.rec.pid"
pypid="$cc_tts_run/live.py.pid"
dispf="$cc_tts_run/live.display"
panef="$cc_tts_run/live.pane"
modef="$cc_tts_run/live.mode"

pane=""; enter=0; action=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pane)   pane="$2"; shift 2 ;;
    --enter)  enter=1; shift ;;
    --stop)   action=stop; shift ;;
    --cancel) action=cancel; shift ;;
    *)        shift ;;
  esac
done
msg() { tmux display-message "$*" 2>/dev/null; }

# Discard: tear everything down without typing anything.
if [ "$action" = cancel ]; then
  kill -INT "$(cat "$recpid" 2>/dev/null)" 2>/dev/null
  kill "$(cat "$pypid" 2>/dev/null)" 2>/dev/null
  [ -f "$dispf" ] && { tmux kill-pane -t "$(cat "$dispf")" 2>/dev/null; rm -f "$dispf"; }
  [ -f "$panef" ] && tmux select-pane -t "$(cat "$panef")" 2>/dev/null
  rm -f "$recpid" "$pypid" "$fifo" "$live" "$live.tmp" "$live.partial" "$live.partial.tmp"
  msg "dictation discarded"
  exit 0
fi

if [ -f "$recpid" ]; then
  # ---------- second press: stop, finish, type ----------
  pane=$(cat "$panef" 2>/dev/null)
  # --enter on the stopping call wins; otherwise use the mode chosen at start.
  [ "$enter" = 1 ] || enter=$(cat "$modef" 2>/dev/null)
  kill -INT "$(cat "$recpid")" 2>/dev/null; rm -f "$recpid"
  # arecord closing the fifo ends the stream; wait for the client to flush.
  p=$(cat "$pypid" 2>/dev/null)
  for _ in $(seq 1 60); do kill -0 "$p" 2>/dev/null || break; sleep 0.1; done
  rm -f "$pypid"

  [ -f "$dispf" ] && { tmux kill-pane -t "$(cat "$dispf")" 2>/dev/null; rm -f "$dispf"; }
  tmux select-pane -t "$pane" 2>/dev/null

  text=$(tr '\n' ' ' < "$final" 2>/dev/null | sed 's/  */ /g; s/^ *//; s/ *$//')
  rm -f "$fifo" "$live" "$live.tmp" "$live.partial" "$live.partial.tmp"
  tts_log "dictate-live pane=$pane enter=$enter chars=${#text}"
  [ -n "$text" ] || { msg "dictation: nothing heard"; exit 0; }

  tmux send-keys -t "$pane" -l "$text"
  [ "$enter" = 1 ] && tmux send-keys -t "$pane" Enter
  exit 0
fi

# ---------- first press: start ----------
if [ -z "${DEEPGRAM_API_KEY:-}${CC_STT_KEY:-}" ]; then
  msg "no DEEPGRAM_API_KEY - add it to ~/.claude/hooks/tts.conf"
  exit 1
fi
export DEEPGRAM_API_KEY CC_STT_KEY
printf '%s' "$pane" > "$panef"; printf '%s' "$enter" > "$modef"
: > "$live"; : > "$final"
rm -f "$fifo"; mkfifo "$fifo"

# Client first so the fifo has a reader, then the recorder.
setsid "$CC_TTS_VENV/bin/python" "$cc_tts_hooks/stt-stream.py" --live "$live" \
  < "$fifo" > "$final" 2>"$cc_tts_run/live.err" &
echo $! > "$pypid"
setsid arecord -q -f S16_LE -r 16000 -c 1 > "$fifo" 2>/dev/null &
echo $! > "$recpid"

# Focused split: the pane takes over, so a bare keypress can end the recording
# without a prefix chord. Killing it hands focus back to where you were.
disp=$(tmux split-window -l 7 -t "$pane" -P -F '#{pane_id}' \
  "$cc_tts_hooks/live-view.sh '$live'" 2>/dev/null)
[ -n "$disp" ] && printf '%s' "$disp" > "$dispf"
