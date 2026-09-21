#!/usr/bin/env bash
# Utterance queue. Sourced by speak.sh; not run directly.
#
# The original design was cancel-on-new: every caller ran tts_cancel before
# tts_speak, so a fresh utterance killed the one in progress. That is right for
# one reply per turn and wrong the moment an agent narrates mid-turn — the
# thing you were listening to disappears halfway through a sentence.
#
# So utterances are now appended to a queue and played in order by a single
# drainer holding a lock. Two hooks firing a millisecond apart cannot both grab
# the audio device, and nothing is lost.
#
# The queue entry carries its own voice. Several sessions share this runtime
# directory and each picks its own voice with prefix+y, so the voice has to
# travel with the text rather than be read when the drainer gets there.
#
# Three ways out of an utterance, and they are deliberately different:
#   skip  (prefix >)  kill the player; the drainer moves to the next entry
#   stop  (prefix V)  kill the player, drop everything still queued
#   pause             not offered: prefix p already means "say that again"

cc_tts_queue="$cc_tts_run/queue"
cc_tts_qlock="$cc_tts_run/queue.lock"
cc_tts_qstop="$cc_tts_run/queue.stop"
mkdir -p "$cc_tts_queue" 2>/dev/null

# Append an utterance. --front jumps the queue, for the two things that are
# genuinely more urgent than narration: a resumed message picking up where it
# was cut, and a permission prompt you are being kept waiting by.
tts_enqueue() {                          # tts_enqueue [--front] <text>
  local front=0
  [ "${1:-}" = "--front" ] && { front=1; shift; }
  local text="${1:-}"
  case "$text" in ''|' ') return 0 ;; esac

  # prefix+V with nothing playing leaves the stop flag behind, since no drainer
  # is running to consume it. Left there it would silently truncate the NEXT
  # batch after its first utterance. Queueing something new ends the silence.
  rm -f "$cc_tts_qstop" 2>/dev/null

  tts_apply_session_voice
  local seq; seq=$(date +%s%N)
  [ "$front" = 1 ] && seq="0000000000000000000"

  # Write then rename: the drainer must never read a half-written entry.
  local tmp="$cc_tts_queue/.$$.$seq"
  { printf '%s\n' "$CC_TTS_VOICE_EDGE"; printf '%s' "$text"; } > "$tmp"
  mv "$tmp" "$cc_tts_queue/$seq.utt"
  tts_log "queued seq=$seq front=$front voice=$CC_TTS_VOICE_EDGE chars=${#text}"

  tts_kick
}

# Start a drainer. Blocking rather than --nonblock on purpose: a drainer that
# has just decided the queue is empty may still hold the lock, and a
# non-blocking caller would give up and leave the entry unspoken. Waiting costs
# an idle process; losing an utterance costs the feature.
tts_kick() {
  setsid flock -w 300 "$cc_tts_qlock" "$cc_tts_hooks/drain.sh" \
    >/dev/null 2>&1 < /dev/null &
}

tts_queue_clear() {
  rm -f "$cc_tts_queue"/*.utt "$cc_tts_queue"/.[0-9]* 2>/dev/null
  return 0
}

tts_queue_depth() {
  local n; n=$(ls -1 "$cc_tts_queue"/*.utt 2>/dev/null | wc -l)
  printf '%s' "$n"
}

# Runs under flock, one at a time. Entries are removed before they are spoken,
# so an utterance that somehow kills the drainer cannot be replayed forever.
tts_drain_loop() {
  local item voice text
  while :; do
    item=$(ls -1 "$cc_tts_queue"/*.utt 2>/dev/null | sort | head -1)
    if [ -z "$item" ]; then
      # A late arrival may have landed between the listing above and here.
      # One short recheck closes that window without polling forever.
      sleep 0.3
      item=$(ls -1 "$cc_tts_queue"/*.utt 2>/dev/null | sort | head -1)
      [ -n "$item" ] || break
    fi
    voice=$(head -1 "$item" 2>/dev/null)
    text=$(tail -n +2 "$item" 2>/dev/null)
    rm -f "$item"
    # The entry's own voice, not whatever the last session happened to set.
    [ -n "$voice" ] && export CC_TTS_VOICE_EDGE="$voice"
    tts_say "$text"
    if [ -f "$cc_tts_qstop" ]; then
      local dropped; dropped=$(tts_queue_depth)
      rm -f "$cc_tts_qstop"
      tts_queue_clear
      tts_log "queue stopped, $dropped dropped"
      break
    fi
  done
}

# "Say this now": jump the queue and drop whatever is mid-sentence. Used by
# prefix+v and by permission prompts -- both are answers to something you are
# waiting on, and queueing them behind three minutes of narration is useless.
# The displaced utterance is still recoverable with prefix+p.
tts_speak_now() {
  tts_enqueue --front "$1"
  tts_cancel
}
