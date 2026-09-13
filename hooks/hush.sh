#!/usr/bin/env bash
# Stop any speech started by these hooks, whichever engine produced it.
. "$(dirname "$0")/speak.sh"
tts_cancel
