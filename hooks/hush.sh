#!/usr/bin/env bash
# prefix+V: stop talking and forget what was waiting. The whole queue goes.
# To drop only the current utterance and hear the next one, use prefix+> .
. "$(dirname "$0")/speak.sh"
n=$(tts_queue_depth)
tts_stop_all
[ "${n:-0}" -gt 0 ] && tmux display-message "speech stopped, $n queued dropped" 2>/dev/null
exit 0
