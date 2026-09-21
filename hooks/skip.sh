#!/usr/bin/env bash
# prefix+>: drop the utterance being spoken and move on to the next one.
#
# tts_cancel is all it takes: the drainer is blocked in tts_say waiting for its
# player, and when that dies it simply picks up the next entry. The stop flag
# is what separates this from prefix+V, and skipping deliberately does not set
# it. The skipped utterance is still recoverable with prefix+p.
. "$(dirname "$0")/speak.sh"
n=$(tts_queue_depth)
tts_cancel
if [ "${n:-0}" -gt 0 ]; then
  tmux display-message "skipped, $n left in queue" 2>/dev/null
else
  tmux display-message "skipped, queue empty" 2>/dev/null
fi
exit 0
