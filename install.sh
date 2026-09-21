#!/usr/bin/env bash
# agentlabs-voice installer. Safe to re-run: everything here is idempotent.
#
#   ./install.sh              full install
#   ./install.sh --no-sudo    skip apt; only report what is missing
#   ./install.sh --no-stt     skip the local whisper model (saves ~150 MB)
#   ./install.sh --no-skills  skip copying the skill into the agent's skills dir
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"
TMUXCONF="$HOME/.tmux.conf"
BINDIR="$HOME/.local/bin"
LIBDIR="$HOME/.local/lib/agentlabs"
SKILLS="$HOME/.claude/skills"
VENV="${CC_TTS_VENV:-$HOME/.venvs/tts}"
MARK_BEGIN="# >>> agentlabs-voice >>>"
MARK_END="# <<< agentlabs-voice <<<"

USE_SUDO=1; WITH_STT=1; WITH_SKILLS=1
for a in "$@"; do
  case "$a" in
    --no-sudo) USE_SUDO=0 ;;
    --no-stt) WITH_STT=0 ;;
    --no-skills) WITH_SKILLS=0 ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done
say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m !\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m  ok\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------- system deps
PKGS=(tmux jq mpg123 alsa-utils speech-dispatcher espeak-ng python3-venv curl)
missing=()
for p in "${PKGS[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
if [ "${#missing[@]}" -eq 0 ]; then ok "system packages present"
elif [ "$USE_SUDO" -eq 1 ] && command -v apt-get >/dev/null 2>&1; then
  say "Installing: ${missing[*]}"
  sudo apt-get update -qq && sudo apt-get install -y "${missing[@]}"
else
  warn "missing packages: ${missing[*]}"
  warn "  sudo apt-get install -y ${missing[*]}"
fi

# ------------------------------------------------------------------ python env
say "Python environment at $VENV"
[ -d "$VENV" ] || python3 -m venv "$VENV"
"$VENV/bin/pip" install --quiet --upgrade pip
PY_PKGS=(edge-tts soundfile websockets)
[ "$WITH_STT" -eq 1 ] && PY_PKGS+=(faster-whisper)
"$VENV/bin/pip" install --quiet "${PY_PKGS[@]}"
ok "${PY_PKGS[*]}"

# ------------------------------------------------------------------- contents
say "Installing to $HOOKS, $BINDIR and $LIBDIR"
mkdir -p "$HOOKS" "$BINDIR" "$LIBDIR" "$HOME/.config/agentlabs"
install -m 0644 "$REPO"/lib/agent.sh "$LIBDIR"/agent.sh
install -m 0644 "$REPO"/lib/transcript.py "$LIBDIR"/transcript.py
install -m 0755 "$REPO"/hooks/*.sh "$HOOKS"/
install -m 0755 "$REPO"/hooks/*.py "$HOOKS"/
install -m 0755 "$REPO"/bin/*      "$BINDIR"/
printf '%s\n' "$REPO" > "$HOME/.config/agentlabs/voice-repo"
ok "$(ls "$REPO"/hooks | wc -l) hooks, $(ls "$REPO"/bin | wc -l) commands"
case ":$PATH:" in
  *":$BINDIR:"*) ok "$BINDIR is on PATH" ;;
  *) warn "$BINDIR is not on PATH. Add to ~/.bashrc or ~/.zshrc:"
     warn "  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

if [ -f "$HOOKS/keyterms.txt" ]; then ok "keyterms.txt kept (yours already exists)"
else install -m 0644 "$REPO/hooks/keyterms.example.txt" "$HOOKS/keyterms.txt"
     ok "keyterms.txt created — add names and jargon you say often"; fi

if [ -f "$HOOKS/tts.conf" ]; then ok "tts.conf kept (yours already exists)"
else install -m 0600 "$REPO/hooks/tts.conf.example" "$HOOKS/tts.conf"
     ok "tts.conf created — add a Deepgram key to enable live dictation"; fi

# ---------------------------------------------------------------------- skill
if [ "$WITH_SKILLS" -eq 1 ] && [ -d "$REPO/skills" ]; then
  mkdir -p "$SKILLS"
  for d in "$REPO"/skills/*/; do
    n=$(basename "$d"); rm -rf "${SKILLS:?}/$n"; cp -r "$d" "$SKILLS/$n"; ok "skill: $n"
  done
fi

# ------------------------------------------------------------- agent settings
# Claude Code hooks. Ours are matched by path and replaced, so any hook you
# added yourself survives a re-run.
if command -v jq >/dev/null 2>&1; then
  say "Registering hooks in $SETTINGS"
  mkdir -p "$(dirname "$SETTINGS")"; [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  tmp=$(mktemp)
  jq --arg stop "$HOOKS/speak-last.sh" --arg note "$HOOKS/speak-notification.sh" '
    def entry($c): {hooks:[{type:"command",command:$c,async:true,timeout:60}]};
    def strip($p): map(select([(.hooks//[])[].command] | any(. as $c | $p | index($c)) | not));
    .hooks = (.hooks // {})
    | .hooks.Stop         = ((.hooks.Stop // [])         | strip([$stop])) + [entry($stop)]
    | .hooks.Notification = ((.hooks.Notification // []) | strip([$note])) + [entry($note)]
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  # voice-offer is called by the AGENT, not by you, so a permission prompt on
  # every mid-turn summary would defeat the point. Allowlist that one command;
  # nothing else is granted.
  tmp=$(mktemp)
  jq --arg rule "Bash($BINDIR/voice-offer:*)" '
    .permissions = (.permissions // {})
    | .permissions.allow = (((.permissions.allow // []) + [$rule]) | unique)
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  ok "Stop and Notification hooks registered; voice-offer allowlisted"
else
  warn "jq not found — register the hooks yourself, see the README"
fi

# Codex uses the same Stop handler. Review new/changed hooks with /hooks.
if command -v jq >/dev/null 2>&1; then
  codex_hooks="${CODEX_HOME:-$HOME/.codex}/hooks.json"
  mkdir -p "$(dirname "$codex_hooks")"
  [ -f "$codex_hooks" ] || printf '{}\n' > "$codex_hooks"
  cp "$codex_hooks" "$codex_hooks.bak.$(date +%Y%m%d%H%M%S)"
  tmp=$(mktemp)
  jq --arg stop "$HOOKS/speak-last.sh" '
    .hooks = (.hooks // {})
    | .hooks.Stop = ((.hooks.Stop // []) | map(
        .hooks |= map(select(.command != $stop))) | map(select(.hooks | length > 0)))
      + [{hooks:[{type:"command",command:$stop,async:true,timeout:60}]}]
  ' "$codex_hooks" > "$tmp" && mv "$tmp" "$codex_hooks"
  ok "Codex Stop hook registered — review and trust it with /hooks"
fi

# ------------------------------------------------------------------------ tmux
say "Adding key bindings to $TMUXCONF"
touch "$TMUXCONF"
sed -i "/$MARK_BEGIN/,/$MARK_END/d" "$TMUXCONF"
{ echo "$MARK_BEGIN"
  echo "source-file $REPO/tmux/voice.tmux.conf"
  echo "$MARK_END"; } >> "$TMUXCONF"
ok "sourced from $REPO/tmux/voice.tmux.conf"
if [ -n "${TMUX:-}" ]; then tmux source-file "$TMUXCONF" 2>/dev/null && ok "reloaded"; fi
prefix=$(tmux show -gv prefix 2>/dev/null || true); prefix="${prefix:-C-b (tmux default)}"

cat <<TXT

$(printf '\033[1m==>\033[0m') Installed.

  Prefix is $prefix.  Press it, then:

    v   read the last reply aloud     V   stop talking, drop the queue
    >   skip to the next utterance    A   auto-speak on/off, this session
    u   where is it right now?
    p   resume where it stopped       y   pick this session's voice
    Space  dictate with live text     N   dictate and send
    m   dictate offline (whisper)     e   dictate offline and send

  Restart your agent so it picks up the hooks.
  Try it:  $HOOKS/demo.sh
TXT
[ -s "$HOOKS/tts.conf" ] && grep -q 'your_key_here' "$HOOKS/tts.conf" 2>/dev/null && {
  warn "Live dictation needs a Deepgram key — see README (offline dictation needs none)"; }
