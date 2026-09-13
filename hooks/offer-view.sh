#!/usr/bin/env bash
# End-of-turn pane: shows the summary that would be spoken and waits for one key.
#
#   space      narrate it
#   esc / q    dismiss
#   any other  dismiss and forward that keystroke to your prompt, so typing
#              straight through the pane does not swallow the character
#
# The pane closes when this script exits.
. "$(dirname "$0")/speak.sh"
f="$1"; back="$2"
text=$(cat "$f" 2>/dev/null)

printf '\033[H\033[J'
printf '  \033[1;36m▸\033[0m summary ready   \033[2mspace = narrate   esc = dismiss\033[0m\n\n'
printf '%s' "$text" | fold -s -w $(( $(tput cols) - 4 )) | sed 's/^/  /'

IFS= read -rsn1 -t "${CC_TTS_OFFER_TIMEOUT:-90}" key
case "$key" in
  ' ')       tmux run-shell -b "$cc_tts_hooks/speak-text.sh '$f'" ;;
  $'\e'|q|Q) : ;;
  '')        : ;;                                   # enter, ctrl+space, timeout
  *)         tmux send-keys -t "$back" -l "$key" ;;  # don't lose the keystroke
esac
tmux select-pane -t "$back" 2>/dev/null
