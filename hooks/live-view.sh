#!/usr/bin/env bash
# Runs inside the dictation pane: renders the live transcript and waits for one
# keypress.
#
#   space        finish, type the text at your cursor
#   ctrl+space   finish, type it AND press Enter
#   enter        same as ctrl+space
#   esc / q      discard
#
# Reads the raw byte rather than using `read -n1`, because bash collapses both
# NUL (ctrl+space) and newline into an empty string and they must be told apart.
live="$1"
hooks="$(dirname "$0")"

( last=""
  cols=$(( $(tput cols) - 4 ))
  while [ -f "$live" ]; do
    final=$(cat "$live" 2>/dev/null)
    part=$(cat "$live.partial" 2>/dev/null)
    if [ "$final$part" != "$last" ]; then
      last="$final$part"
      # Settled words bright, still-being-revised words dim, so the guessing
      # that streaming recognition does is visible rather than confusing.
      printf '\033[H\033[J'
      printf '  \033[1;31m●\033[0m listening   \033[2mspace = insert   ctrl+space = insert & send   esc = discard\033[0m\n\n'
      printf '%s \033[2m%s\033[0m' "$final" "$part" \
        | fold -s -w "$cols" | sed 's/^/  /'
    fi
    sleep 0.1
  done ) &
renderer=$!

saved=$(stty -g 2>/dev/null)
stty raw -echo 2>/dev/null
byte=$(dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
[ -n "$saved" ] && stty "$saved" 2>/dev/null
kill "$renderer" 2>/dev/null

printf '%s live-view byte=%s\n' "$(date +%H:%M:%S)" "${byte:-EMPTY}" \
  >> "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/claude-tts-$(id -u)/debug.log" 2>/dev/null

case "$byte" in
  00|0d|0a) args="--stop --enter" ;;   # ctrl+space, enter
  1b|71|51) args="--cancel" ;;         # esc, q, Q
  *)        args="--stop" ;;           # space, anything else
esac
# Detached in the tmux server: this pane is about to be killed.
tmux run-shell -b "$hooks/dictate-live.sh $args"
