#!/usr/bin/env bash
# Remove agentlabs-voice. Keeps tts.conf and the venv unless --purge.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$HOME/.claude/hooks"; SETTINGS="$HOME/.claude/settings.json"
TMUXCONF="$HOME/.tmux.conf"; BINDIR="$HOME/.local/bin"; SKILLS="$HOME/.claude/skills"
VENV="${CC_TTS_VENV:-$HOME/.venvs/tts}"
PURGE=0; [ "${1:-}" = "--purge" ] && PURGE=1
echo "==> tmux bindings"
[ -f "$TMUXCONF" ] && sed -i '/# >>> agentlabs-voice >>>/,/# <<< agentlabs-voice <<</d' "$TMUXCONF"
[ -n "${TMUX:-}" ] && tmux source-file "$TMUXCONF" 2>/dev/null || true
echo "==> hooks"
if [ -f "$SETTINGS" ] && command -v jq >/dev/null; then
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  tmp=$(mktemp)
  jq --arg h "$HOOKS/" 'def strip: map(select([(.hooks//[])[].command]|any(startswith($h))|not));
    if .hooks then .hooks.Stop=((.hooks.Stop//[])|strip)
      | .hooks.Notification=((.hooks.Notification//[])|strip)
      | .hooks |= with_entries(select(.value|length>0)) else . end' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  # and the one permission the installer granted the agent
  tmp=$(mktemp)
  jq --arg rule "Bash($BINDIR/voice-offer:*)" '
    if .permissions.allow then .permissions.allow |= map(select(. != $rule)) else . end
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
fi
codex_hooks="${CODEX_HOME:-$HOME/.codex}/hooks.json"
if [ -f "$codex_hooks" ] && command -v jq >/dev/null; then
  cp "$codex_hooks" "$codex_hooks.bak.$(date +%Y%m%d%H%M%S)"
  tmp=$(mktemp)
  jq --arg stop "$HOOKS/speak-last.sh" '
    if .hooks.Stop then .hooks.Stop |= (map(.hooks |= map(select(.command != $stop)))
      | map(select(.hooks | length > 0))) else . end
  ' "$codex_hooks" > "$tmp" && mv "$tmp" "$codex_hooks"
fi
for f in "$REPO"/hooks/*.sh "$REPO"/hooks/*.py; do rm -f "$HOOKS/$(basename "$f")"; done
for f in "$REPO"/bin/*; do rm -f "$BINDIR/$(basename "$f")"; done
for d in "$REPO"/skills/*/; do [ -d "$d" ] && rm -rf "$SKILLS/$(basename "$d")"; done
rm -f "$HOME/.config/agentlabs/voice-repo"
if [ "$PURGE" -eq 1 ]; then rm -f "$HOOKS/tts.conf"; rm -rf "$VENV"; echo "==> purged config and venv"
else echo "    kept $HOOKS/tts.conf and $VENV (--purge removes them)"; fi
echo "==> Done. Restart your agent."
