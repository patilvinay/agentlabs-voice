#!/usr/bin/env bash
# The offer pane: shows the summary that would be spoken and waits for one key.
#
#   space      narrate it
#   esc / q    dismiss
#   any other  dismiss and forward that keystroke to your prompt, so typing
#              straight through the pane does not swallow the character
#
# It REDRAWS while it waits. An agent narrating mid-turn can produce a second
# summary before you have looked up, and tts_offer appends it to this same
# file; a pane that rendered once and then blocked on a keypress would show
# the first and silently lose the second. Same background-renderer shape as
# live-view.sh, for the same reason.
#
# The pane closes when this script exits.
. "$(dirname "$0")/speak.sh"
f="$1"; back="$2"

render() {
  local n; n=$(grep -c $'\f' "$f" 2>/dev/null); n=$(( ${n:-0} + 1 ))
  printf '\033[H\033[J'
  if [ "$n" -gt 1 ]; then
    printf '  \033[1;36m▸\033[0m %s summaries ready   \033[2mspace = narrate all   esc = dismiss\033[0m\n\n' "$n"
  else
    printf '  \033[1;36m▸\033[0m summary ready   \033[2mspace = narrate   esc = dismiss\033[0m\n\n' 
  fi
  sed 's/\f/──────/' "$f" 2>/dev/null \
    | fold -s -w $(( $(tput cols) - 4 )) | sed 's/^/  /'
}

( last=""
  while :; do
    now=$(stat -c %Y-%s "$f" 2>/dev/null)
    [ "$now" != "$last" ] && { last="$now"; render; }
    sleep 0.2
  done ) &
renderer=$!
trap 'kill "$renderer" 2>/dev/null' EXIT

IFS= read -rsn1 -t "${CC_TTS_OFFER_TIMEOUT:-90}" key
kill "$renderer" 2>/dev/null

case "$key" in
  ' ')       tmux run-shell -b "$cc_tts_hooks/speak-text.sh '$f'" ;;
  $'\e'|q|Q) : ;;
  '')        : ;;                                   # enter, ctrl+space, timeout
  *)         tmux send-keys -t "$back" -l "$key" ;;  # don't lose the keystroke
esac
tmux select-pane -t "$back" 2>/dev/null
