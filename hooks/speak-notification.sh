#!/usr/bin/env bash
# Claude Code Notification hook: speak the notification aloud.
# Synthesis lives in speak.sh.
#
# Idle nudges ("Claude is waiting for your input") fire whenever you pause,
# which is constant and useless — you are looking at the screen. They are
# skipped by default. Permission prompts still speak, because those are the
# ones you might miss while looking elsewhere.
#
# Tune with CC_TTS_NOTIFY_SKIP in tts.conf (an extended regex, case
# insensitive). Set it to an unmatchable string to speak everything again.

. "$(dirname "$0")/speak.sh"

CC_TTS_NOTIFY_SKIP="${CC_TTS_NOTIFY_SKIP:-waiting for your input|waiting for input|is idle|idle for}"

raw=$(jq -r '.message // empty')

if [ -n "$raw" ] && printf '%s' "$raw" | grep -qiE "$CC_TTS_NOTIFY_SKIP"; then
  tts_log "notification SKIPPED: ${raw:0:60}"
  exit 0
fi

text=$(printf '%s' "$raw" | tts_clean)
tts_cancel
tts_speak "$text"
exit 0
