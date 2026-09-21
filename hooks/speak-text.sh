#!/usr/bin/env bash
# Speak the contents of an offer file. Used by the offer pane.
#
# The file may hold several summaries separated by \f, because the agent can
# narrate more than once before you press space. Each becomes its own queue
# entry, so prefix+> skips one summary rather than all of them.
. "$(dirname "$0")/speak.sh"
[ -f "$1" ] || exit 0
while IFS= read -r -d $'\f' chunk || [ -n "$chunk" ]; do
  case "${chunk//[[:space:]]/}" in '') continue ;; esac
  tts_speak "$chunk"
done < "$1"
