#!/usr/bin/env bash
# Speak the contents of a file. Used by the end-of-turn offer pane.
. "$(dirname "$0")/speak.sh"
text=$(cat "$1" 2>/dev/null)
case "$text" in ''|' ') exit 0 ;; esac
tts_cancel
tts_speak "$text"
