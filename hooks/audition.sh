#!/usr/bin/env bash
# Play the same line through several voices so you can pick one.
# Usage: audition.sh ["custom text"]
. "$(dirname "$0")/speak.sh"
TEXT="${1:-Found it. Cancelling the speech was being treated as an error, so it fell back and re-read the whole message in the offline voice. That is fixed now, and all three cases are tested.}"
VOICES=(
  "en-US-AvaMultilingualNeural|Ava - expressive, caring, pleasant"
  "en-US-AndrewMultilingualNeural|Andrew - warm, confident, authentic"
  "en-US-BrianMultilingualNeural|Brian - approachable, casual, sincere"
  "en-US-EmmaMultilingualNeural|Emma - cheerful, clear, conversational"
  "en-US-AriaNeural|Aria - your current voice, newsreader style"
)
i=0
for entry in "${VOICES[@]}"; do
  i=$((i+1))
  v="${entry%%|*}"; d="${entry#*|}"
  printf '\n\033[1m%d. %s\033[0m\n   %s\n' "$i" "$d" "$v"
  CC_TTS_VOICE_EDGE="$v" tts_speak "Voice $i. $TEXT"
done
printf '\n\033[1mSet one with: CC_TTS_VOICE_EDGE in ~/.claude/hooks/tts.conf\033[0m\n'
