#!/usr/bin/env bash
# Stop hook: speak the agent's last message aloud.
#
# Two races to defend against, both of which made older text get spoken:
#   1. The hook can fire before the final assistant message is flushed to the
#      transcript, leaving a mid-turn preamble as the newest entry.
#   2. If nothing new arrived, the naive "last entry" lookup re-speaks the
#      message from the previous turn.
# So: wait for the file to settle, then speak only if the newest text entry is
# one we have not already spoken (tracked by uuid).

. "$(dirname "$0")/speak.sh"

CC_TTS_SETTLE="${CC_TTS_SETTLE:-5}"       # max seconds to wait for the flush
log="$cc_tts_run/debug.log"

t=$(jq -r '.transcript_path // empty')
export CC_TTS_TRANSCRIPT="$t"

# Remember which transcript belongs to this tmux pane, before any early exit.
# Several Claude sessions can share one project directory, so "newest file in
# the directory" would let the manual trigger speak a sibling session's reply.
agent_remember_pane "${TMUX_PANE:-}" "$t"

# Speak automatically (AUTO), offer a pane at end of turn (OFFER), or neither.
[ "${CC_TTS_AUTO:-1}" = 1 ] || [ "${CC_TTS_OFFER:-0}" = 1 ] || exit 0

[ -n "$t" ] && [ -f "$t" ] || exit 0

state="$cc_tts_run/last-spoken.uuid"
prev=$(cat "$state" 2>/dev/null)

# Newest assistant entry that carries text, as "uuid<TAB>text".
newest() {
  jq -rs '[.[]
           | select(.type=="assistant")
           | select(any(.message.content[]?; .type=="text" and (.text|length)>0))]
          | last
          | "\(.uuid // "no-uuid")\t\(.message.content | map(select(.type=="text") | .text) | join(" "))"' "$t" 2>/dev/null
}

# Poll until the transcript stops growing AND the newest entry is unseen,
# whichever resolves first. Bounded by CC_TTS_SETTLE.
deadline=$(( $(date +%s) + CC_TTS_SETTLE ))
size=0; stable=0; row=""
while :; do
  now=$(stat -c %s "$t" 2>/dev/null || echo 0)
  [ "$now" = "$size" ] && stable=$((stable + 1)) || stable=0
  size=$now
  row=$(newest)
  uuid=${row%%$'\t'*}
  # Settled: file quiet for ~0.6s and we are looking at something new.
  [ "$stable" -ge 3 ] && [ -n "$uuid" ] && [ "$uuid" != "$prev" ] && break
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.2
done

uuid=${row%%$'\t'*}
text=$(printf '%s' "${row#*$'\t'}" | tts_resolve)

[ "$CC_TTS_DEBUG" = 1 ] && printf '%s fired uuid=%.8s prev=%.8s stable=%s %s\n' \
  "$(date +%H:%M:%S)" "$uuid" "${prev:-none}" "$stable" \
  "$([ "$uuid" = "$prev" ] && echo SKIP-already-spoken || echo SPEAK)" >> "$log"

# Nothing new arrived: stay silent rather than repeat the previous turn.
[ -n "$uuid" ] && [ "$uuid" != "$prev" ] || exit 0

printf '%s' "$uuid" > "$state"

# Speaking over you while you are reading another session is worse than
# silence. prefix+v still replays this pane on demand.
if [ "${CC_TTS_ONLY_ACTIVE:-1}" = 1 ] && ! tts_pane_is_active "$TMUX_PANE"; then
  tts_log "silent: pane $TMUX_PANE not on screen"
  exit 0
fi

if [ "${CC_TTS_OFFER:-0}" = 1 ] && [ -n "$TMUX_PANE" ]; then
  # Offer rather than speak: a small pane shows the summary and waits for a key.
  offer="$cc_tts_run/offer.txt"
  printf '%s' "$text" > "$offer"
  # Don't stack panes if one from a previous turn is still open.
  prev=$(cat "$cc_tts_run/offer.pane" 2>/dev/null)
  [ -n "$prev" ] && tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$prev" && exit 0
  disp=$(tmux split-window -l 7 -t "$TMUX_PANE" -P -F '#{pane_id}' \
    "$cc_tts_hooks/offer-view.sh '$offer' '$TMUX_PANE'" 2>/dev/null)
  [ -n "$disp" ] && printf '%s' "$disp" > "$cc_tts_run/offer.pane"
  exit 0
fi

tts_cancel
tts_speak "$text"
