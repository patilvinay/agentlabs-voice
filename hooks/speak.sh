#!/usr/bin/env bash
# Shared TTS helper for Claude Code hooks; sourced, not run directly.
#
# Engine comes from CC_TTS_ENGINE, else ~/.claude/hooks/tts.conf, else spd:
#   spd  - offline, speech-dispatcher -> espeak-ng. Instant, robotic.
#   edge - online, Microsoft Edge neural voices. Natural, ~1s latency,
#          and the text leaves the machine. Falls back to spd if it fails.

CC_TTS_CONF="${CC_TTS_CONF:-$HOME/.claude/hooks/tts.conf}"
# shellcheck source=/dev/null
[ -f "$CC_TTS_CONF" ] && . "$CC_TTS_CONF"

CC_TTS_ENGINE="${CC_TTS_ENGINE:-spd}"
CC_TTS_MAXCHARS="${CC_TTS_MAXCHARS:-4000}"   # fallback path only; <voice> is never trimmed
CC_TTS_RATE_SPD="${CC_TTS_RATE_SPD:-30}"              # -100..100
CC_TTS_VOICE_EDGE="${CC_TTS_VOICE_EDGE:-en-US-AriaNeural}"
CC_TTS_RATE_EDGE="${CC_TTS_RATE_EDGE:-+15%}"
CC_TTS_VENV="${CC_TTS_VENV:-$HOME/.venvs/tts}"
# Stream synthesis into the player rather than waiting for the whole file.
# Needs mpg123, since aplay cannot read mp3 from a pipe.
CC_TTS_STREAM="${CC_TTS_STREAM:-1}"
# Resume (prefix+p) after an interrupted utterance. Both are seconds.
#   LAG    - streaming synthesis latency: how long after the pipeline starts
#            that audio actually begins. Subtracted so resume is not ahead.
#   REWIND - deliberately rejoin slightly before the cut, so you hear the
#            end of the interrupted phrase again instead of missing a word.
CC_TTS_RESUME_LAG="${CC_TTS_RESUME_LAG:-1.0}"
CC_TTS_RESUME_REWIND="${CC_TTS_RESUME_REWIND:-1.5}"
# Speaking speed used to map "stopped at N seconds" back onto the text.
# Measured for edge-tts en-US at +15%: 93 chars / 5.83 s = 16.0 chars/sec.
CC_TTS_RESUME_CPS="${CC_TTS_RESUME_CPS:-16.0}"
# 1 = the Stop hook stays quiet unless the pane it belongs to is the one you
# are actually looking at. Several sessions can then run at once without
# talking over each other. Manual playback (prefix+v) always speaks.
CC_TTS_ONLY_ACTIVE="${CC_TTS_ONLY_ACTIVE:-1}"
cc_tts_hooks="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Which agent is in this pane, and where its transcript lives. Everything
# agent-specific is in that one file; nothing here names Claude or Codex.
for _c in "$cc_tts_hooks/../lib/agent.sh" "$HOME/.local/lib/agentlabs/agent.sh"; do
  [ -f "$_c" ] && { . "$_c"; break; }
done

CC_TTS_DEBUG="${CC_TTS_DEBUG:-1}"
# Resolve from the filesystem, not $XDG_RUNTIME_DIR: tmux's server does not
# export it, so run-shell (both key bindings) would otherwise compute a
# different directory than the hooks and lose track of pidfiles and mappings.
cc_tts_uid=$(id -u)
if [ -d "/run/user/$cc_tts_uid" ]; then
  cc_tts_run="/run/user/$cc_tts_uid/claude-tts-$cc_tts_uid"
else
  cc_tts_run="/tmp/claude-tts-$cc_tts_uid"
fi
mkdir -p "$cc_tts_run" 2>/dev/null

# Records which engine actually produced audio, so a silent fallback to the
# offline voice is visible after the fact instead of a guess.
tts_log() {
  [ "$CC_TTS_DEBUG" = 1 ] || return 0
  printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >> "$cc_tts_run/debug.log"
}

# Pull out <voice>…</voice> if the message carries one, so a response can
# supply a short spoken summary distinct from its on-screen text. Emits
# nothing when there is no such block, and the caller then falls back to
# speaking the whole message.
tts_voice() {
  awk '
    { line = $0
      while (1) {
        if (!inv) {
          i = index(line, "<voice>")
          if (i == 0) break
          line = substr(line, i + 7); inv = 1
        }
        j = index(line, "</voice>")
        if (j == 0) { print line; break }
        print substr(line, 1, j - 1); inv = 0; line = substr(line, j + 8)
      }
    }
  '
}

# Trim to CC_TTS_MAXCHARS at a sentence boundary so speech never stops
# mid-word. Falls back to a word boundary if there is no sentence end in
# range. CC_TTS_MAXCHARS=0 means no limit.
#
# This applies ONLY to the fallback path that speaks a whole reply. A <voice>
# block is written to be heard and must never be trimmed: silently dropping
# two thirds of a long one is worse than taking longer to say it. edge-tts
# handles several thousand characters in a single request, and streaming means
# playback still starts in about a second regardless of length.
tts_fit() {
  awk -v max="$CC_TTS_MAXCHARS" '{
    if (max <= 0 || length($0) <= max) { print; exit }
    h = substr($0, 1, max); p = 0
    for (i = length(h); i >= 1; i--) {
      c = substr(h, i, 1)
      if (c == "." || c == "!" || c == "?") { p = i; break }
    }
    if (p >= max * 0.4) { print substr(h, 1, p); exit }
    for (i = length(h); i >= 1; i--) if (substr(h, i, 1) == " ") { p = i - 1; break }
    print substr(h, 1, p)
  }'
}

# Strip markup that reads badly aloud: fenced code, table rows, list bullets,
# link targets, stray markdown punctuation. Then collapse whitespace and fit.
tts_clean() {
  sed -e '/^```/,/^```/d' \
      -e '/^[[:space:]]*|/d' \
      -e 's/\[\([^]]*\)\]([^)]*)/\1/g' \
      -e 's/^[[:space:]]*[-*+][[:space:]]\+/ /' \
      -e 's/[`*#_>|]//g' \
    | tr -s '[:space:]' ' ' \
    | tts_fit
}

# Record how far playback got, so tts_resume can pick it up. Called from
# tts_cancel before anything is killed.
#
# Position is measured from wall clock rather than from the decoder, because
# mpg123 reports nothing back to us. It is therefore approximate: the lag and
# rewind offsets above absorb the error, and erring early is the kind of wrong
# a listener does not notice.
tts_mark_stop() {
  local start now el base lag
  start=$(cat "$cc_tts_run/play.start" 2>/dev/null) || return 0
  [ -n "$start" ] || return 0
  base=$(cat "$cc_tts_run/resume.base" 2>/dev/null); base=${base:-0}
  lag=$(cat "$cc_tts_run/play.lag" 2>/dev/null); lag=${lag:-0}
  now=$(date +%s%N)
  el=$(awk -v a="$now" -v b="$start" 'BEGIN{printf "%.3f",(a-b)/1000000000}')
  awk -v e="$el" -v b="$base" -v l="$lag" -v r="$CC_TTS_RESUME_REWIND" \
      'BEGIN{p=b+e-l-r; if(p<0)p=0; printf "%.3f",p}' > "$cc_tts_run/resume.sec"
  rm -f "$cc_tts_run/play.start"
  tts_log "stopped at $(cat "$cc_tts_run/resume.sec")s"
}

# Resume an interrupted utterance.
#
# Seeking into say.mp3 was the obvious approach and is wrong: cancelling kills
# the synthesiser too, so the file only holds audio up to the interruption.
# Replaying it would repeat the fragment and then stop, never reaching the part
# you actually missed.
#
# So resume works on the TEXT. The stop position in seconds is converted to a
# character offset with CC_TTS_RESUME_CPS, then snapped BACK to the start of
# the sentence containing it — restarting mid-sentence sounds broken, and an
# estimate that is a few words out disappears entirely once it lands on a
# sentence boundary. The remainder is then spoken normally, so it runs to the
# end of the message and works on either engine.
tts_resume() {
  local txt="$cc_tts_run/say.txt" sec rest
  if [ ! -s "$txt" ]; then tts_log "resume: nothing to resume"; return 1; fi
  sec=$(cat "$cc_tts_run/resume.sec" 2>/dev/null); sec=${sec:-0}

  rest=$(awk -v sec="$sec" -v cps="$CC_TTS_RESUME_CPS" '
    { t = t $0 " " }
    END {
      n = length(t)
      off = int(sec * cps)
      if (off <= 0)  { print t; exit }
      if (off >= n)  { exit }              # nothing left to say
      # snap back to the sentence boundary at or before the offset
      p = 0
      for (i = off; i >= 1; i--) {
        c = substr(t, i, 1)
        if (c == "." || c == "!" || c == "?") { p = i + 1; break }
      }
      # no sentence end found nearby: fall back to a word boundary
      if (p == 0) { for (i = off; i >= 1; i--) if (substr(t,i,1) == " ") { p = i + 1; break } }
      if (p == 0) p = 1
      s = substr(t, p)
      sub(/^[[:space:]]+/, "", s)
      print s
    }' "$txt")

  if [ -z "${rest//[[:space:]]/}" ]; then
    tts_log "resume: already at the end"
    return 1
  fi
  tts_log "resume from ${sec}s -> ${#rest} chars remaining"
  tts_speak "$rest"
}

# Silence anything we started earlier. Uses a pidfile so an unrelated
# aplay of the user's own stays untouched.
tts_cancel() {
  tts_mark_stop
  # Invalidate the in-flight generation so an utterance still being
  # synthesised does not start playing after this returns.
  printf 'cancelled' > "$cc_tts_run/gen" 2>/dev/null
  spd-say -C 2>/dev/null
  if [ -f "$cc_tts_run/play.pid" ]; then
    local p pg; p=$(cat "$cc_tts_run/play.pid")
    # Streaming runs synth|player as a group; kill the whole group so neither
    # half survives. Resolve the pgid rather than assuming pid == pgid.
    pg=$(ps -o pgid= -p "$p" 2>/dev/null | tr -d ' ')
    [ -n "$pg" ] && kill -- "-$pg" 2>/dev/null
    kill "$p" 2>/dev/null
    rm -f "$cc_tts_run/play.pid"
  fi
}


# ---------------------------------------------------------------- session id
# Which Claude session does this call belong to? In hook context the transcript
# path is authoritative; from a key binding we only have the pane, so fall back
# to the pane->transcript map speak-last.sh keeps.
# TMUX_PANE is EMPTY inside both run-shell bindings and display-popup, so it
# cannot be relied on: callers that know their pane pass it in CC_TTS_PANE.
tts_session_id() {
  local t="${1:-${CC_TTS_TRANSCRIPT:-}}" pane
  if [ -n "$t" ]; then agent_session_id "$t"; return 0; fi
  for pane in "${CC_TTS_PANE:-}" "${TMUX_PANE:-}"; do
    [ -n "$pane" ] || continue
    t=$(agent_pane_transcript "$pane" 2>/dev/null) || continue
    agent_session_id "$t"; return 0
  done
  return 1
}

# Per-session voice, chosen with prefix+y and stored beside the session's
# scratchpad so it survives reboots. Falls back to the configured default.
tts_session_voice_file() {
  local sid; sid=$(tts_session_id "${1:-}") || return 1
  printf '%s/.voice' "${AGENTLABS_SESSIONS:-$HOME/.claude/scratch}/$sid"
}

tts_apply_session_voice() {
  local f v
  f=$(tts_session_voice_file "${1:-}") || return 0
  [ -f "$f" ] || return 0
  v=$(tr -d '[:space:]' < "$f")
  # Must be exported: the streaming player is a separate process that sources
  # this file again, and a plain assignment here would be invisible to it --
  # it would fall back to the configured default and use the wrong voice.
  [ -n "$v" ] && export CC_TTS_VOICE_EDGE="$v"
}

# Resume runs from a key binding with no session to resolve, and must not
# switch voice mid-message; tts_speak records what it used.
tts_recall_voice() {
  local f="$cc_tts_run/voice.last"
  [ -f "$f" ] && export CC_TTS_VOICE_EDGE="$(cat "$f")"
}

# Is the pane this hook belongs to on screen? Visibility, not focus: Claude
# usually sits in one pane while you type in its neighbour, so requiring
# pane_active would silence the common case. What matters is that the pane's
# window is the selected one and some client is actually attached.
tts_pane_is_active() {
  local pane="${1:-$TMUX_PANE}" win att
  [ -n "$pane" ] || return 0                 # not under tmux: nothing to gate on
  command -v tmux >/dev/null 2>&1 || return 0
  win=$(tmux display -p -t "$pane" '#{window_active}' 2>/dev/null) || return 0
  att=$(tmux display -p -t "$pane" '#{session_attached}' 2>/dev/null) || return 0
  [ "$win" = 1 ] && [ "${att:-0}" -ge 1 ]
}

tts_spd() { spd-say -w -r "$CC_TTS_RATE_SPD" -- "$1"; }

# edge-tts emits mp3. mpg123 plays it directly; without it, decode to wav
# through soundfile and hand that to aplay.
# Synthesis only. Non-zero here means edge genuinely failed (offline, bad
# voice) and the caller should fall back to espeak.
tts_edge_synth() {
  "$CC_TTS_VENV/bin/edge-tts" -v "$CC_TTS_VOICE_EDGE" --rate="$CC_TTS_RATE_EDGE" \
      --text "$1" --write-media "$cc_tts_run/say.mp3" 2>/dev/null || return 1
  command -v mpg123 >/dev/null 2>&1 && return 0
  # No mpg123: decode to wav for aplay.
  "$CC_TTS_VENV/bin/python" -c '
import sys, soundfile as sf
data, rate = sf.read(sys.argv[1])
sf.write(sys.argv[2], data, rate, subtype="PCM_16")' \
    "$cc_tts_run/say.mp3" "$cc_tts_run/say.wav" 2>/dev/null
}

# Streaming playback: synthesis and audio overlap. setsid puts the pipeline in
# its own process group so tts_cancel can take down both halves at once.
tts_edge_stream() {
  local gen="$1" text="$2" pid rc
  [ "$(cat "$cc_tts_run/gen" 2>/dev/null)" = "$gen" ] || return 0
  setsid "$cc_tts_hooks/edge-play.sh" "$text" "$gen" & pid=$!
  wait "$pid"; rc=$?
  rm -f "$cc_tts_run/play.pid"
  return "$rc"
}

# Playback only. A kill here is a cancellation, not a failure, so its exit
# status is deliberately discarded — returning non-zero would make the caller
# fall back and re-read the whole message in the other voice.
tts_edge_play() {
  local gen="$1" pid
  # Bail out if tts_cancel ran while we were synthesising.
  [ "$(cat "$cc_tts_run/gen" 2>/dev/null)" = "$gen" ] || return 0
  printf '0' > "$cc_tts_run/resume.base"
  printf '0' > "$cc_tts_run/play.lag"
  date +%s%N > "$cc_tts_run/play.start"
  if command -v mpg123 >/dev/null 2>&1; then
    mpg123 -q "$cc_tts_run/say.mp3" & pid=$!
  else
    aplay -q "$cc_tts_run/say.wav" & pid=$!
  fi
  echo "$pid" > "$cc_tts_run/play.pid"
  wait "$pid" 2>/dev/null || true
  rm -f "$cc_tts_run/play.pid" "$cc_tts_run/play.start"
  return 0
}

tts_speak() {
  local text="$1"
  case "$text" in ''|' ') return 0 ;; esac
  tts_apply_session_voice
  printf '%s' "$CC_TTS_VOICE_EDGE" > "$cc_tts_run/voice.last" 2>/dev/null
  # Keep the utterance on disk so an interrupted one can be resumed by text.
  printf '%s' "$text" > "$cc_tts_run/say.txt" 2>/dev/null
  local gen
  gen=$(date +%s%N)
  printf '%s' "$gen" > "$cc_tts_run/gen" 2>/dev/null
  case "$CC_TTS_ENGINE" in
    off|none|"") return 0 ;;
    edge)
      local rc
      if [ "$CC_TTS_STREAM" = 1 ] && command -v mpg123 >/dev/null 2>&1; then
        tts_edge_stream "$gen" "$text"; rc=$?
        case "$rc" in
          0)             tts_log "engine=edge mode=stream voice=$CC_TTS_VOICE_EDGE chars=${#text}" ;;
          129|130|143)   tts_log "engine=edge mode=stream CANCELLED" ;;
          *)             tts_log "engine=spd FALLBACK (stream rc=$rc) chars=${#text}"
                         tts_spd "$text" ;;
        esac
      elif tts_edge_synth "$text"; then
        tts_log "engine=edge mode=buffered voice=$CC_TTS_VOICE_EDGE chars=${#text}"
        tts_edge_play "$gen"
      else
        tts_log "engine=spd FALLBACK (edge synth failed) chars=${#text}"
        tts_spd "$text"
      fi
      ;;
    *) tts_log "engine=spd chars=${#text}"; tts_spd "$text" ;;
  esac
}

# Given a full assistant message on stdin, return the text to speak.
tts_resolve() {
  local raw voice out full
  raw=$(cat)
  voice=$(printf '%s\n' "$raw" | tts_voice)
  if [ -n "${voice//[[:space:]]/}" ]; then
    # Authored for the ear: say all of it.
    CC_TTS_MAXCHARS=0 tts_clean <<< "$voice"
    return 0
  fi
  # No <voice> block: this is the whole reply, which can be enormous. Cap it,
  # but say so rather than stopping mid-thought as though that were the end.
  full=$(CC_TTS_MAXCHARS=0 tts_clean <<< "$raw")
  out=$(printf '%s' "$full" | tts_clean)
  printf '%s' "$out"
  [ "${#out}" -lt "${#full}" ] && printf ' … message truncated.'
  printf '\n'
}
