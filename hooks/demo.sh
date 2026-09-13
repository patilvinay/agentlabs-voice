#!/usr/bin/env bash
# Audible walkthrough of the TTS setup. Re-runnable: ~/.claude/hooks/demo.sh
. "$(dirname "$0")/speak.sh"
rm -f "$cc_tts_run/debug.log"
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

step "1/5  Online neural voice, streamed (measuring time to first sound)"
S=$(date +%s.%N)
( tts_speak "Step one. This is the online neural voice, streaming as it arrives." ) & BG=$!
until pgrep -x mpg123 >/dev/null 2>&1; do sleep 0.02; done
printf '      first sound after %.2fs\n' "$(echo "$(date +%s.%N) - $S" | bc)"
wait $BG 2>/dev/null

step "2/5  Offline voice, for contrast"
CC_TTS_ENGINE=spd tts_speak "Step two. This is the offline robotic voice."

step "3/5  Voice block: the long body is skipped, only the block is spoken"
msg='Here is a detailed technical answer with a table and code that would take ages to read aloud.

| Setting | Value |
|---|---|
| engine | edge |

<voice>Step three. Only this sentence is spoken, not the table above it.</voice>'
printf '      resolves to: "%s"\n' "$(printf '%s\n' "$msg" | tts_resolve)"
tts_speak "$(printf '%s\n' "$msg" | tts_resolve)"

step "4/5  Cancel mid-sentence (stops dead, no second voice starts)"
( tts_speak "Step four. I am going to keep talking for quite a long time now, and you should never hear the end of this sentence because it gets cut off." ) & BG=$!
until [ -f "$cc_tts_run/play.pid" ]; do sleep 0.05; done
sleep 2.2
"$(dirname "$0")/hush.sh"
sleep 1.5
if pgrep -x mpg123 >/dev/null || pgrep -x spd-say >/dev/null; then echo "      FAIL: still speaking"; else echo "      silent - nothing survived"; fi
wait $BG 2>/dev/null

step "5/5  Online fails -> automatic fallback to local"
CC_TTS_VOICE_EDGE=bogus-voice tts_speak "Step five. The online voice failed, so this is the local one."

step "engine log"
sed 's/^/      /' "$cc_tts_run/debug.log"
printf '\n\033[1mPress prefix v to replay any message, prefix V to stop.\033[0m\n'
