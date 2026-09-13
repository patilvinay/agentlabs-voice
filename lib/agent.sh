#!/usr/bin/env bash
# Which coding agent is in this pane, and where is its transcript?
#
# Sourced by both agentlabs-voice and agentlabs-ideas-skill. Everything that
# differs between Claude Code and Codex lives here, so the rest of either
# project never names an agent.
#
# STATUS
#   Claude Code — implemented and tested.
#   Codex CLI   — implemented from its documented layout, NOT yet verified on a
#                 machine with Codex installed. If it misbehaves, this file is
#                 the only place to look; nothing else knows about agents.
#
# The pane→transcript map is shared between both projects, so installing either
# one is enough and installing both does not duplicate the work.

agentlabs_run() {
  local uid; uid=$(id -u)
  if [ -d "/run/user/$uid" ]; then printf '/run/user/%s/agentlabs' "$uid"
  else printf '/tmp/agentlabs-%s' "$uid"; fi
}

AGENTLABS_RUN="${AGENTLABS_RUN:-$(agentlabs_run)}"
mkdir -p "$AGENTLABS_RUN" 2>/dev/null

# Record which transcript a pane's agent is writing. Called from whatever hook
# a project installs; the map is what lets a key binding in a neighbouring
# shell pane resolve the right session.
agent_remember_pane() {                 # agent_remember_pane <pane> <transcript>
  local pane="${1:-}" t="${2:-}"
  [ -n "$pane" ] && [ -n "$t" ] || return 0
  printf '%s' "$t" > "$AGENTLABS_RUN/pane-${pane#%}.transcript"
}

agent_pane_transcript() {               # agent_pane_transcript <pane>
  local f="$AGENTLABS_RUN/pane-${1#%}.transcript"
  [ -f "$f" ] || return 1
  local t; t=$(cat "$f"); [ -f "$t" ] || return 1
  printf '%s' "$t"
}

# --- per-agent transcript stores -------------------------------------------
# Newest transcript for a working directory, used when no pane map exists yet
# (the first turn of a session, or a manual run outside tmux).

_agent_claude_newest() {                # _agent_claude_newest <cwd>
  local slug dir
  slug=$(printf '%s' "$1" | sed 's/[/.]/-/g')
  dir="$HOME/.claude/projects/$slug"
  [ -d "$dir" ] || dir="$HOME/.claude/projects"
  [ -d "$dir" ] || return 1
  find "$dir" -maxdepth 2 -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-
}

# UNTESTED. Codex keeps rollout transcripts under ~/.codex/sessions, dated
# directories, one .jsonl per session. Newest wins; there is no per-directory
# split to narrow by, so this is less precise than the Claude case.
_agent_codex_newest() {                 # _agent_codex_newest <cwd>
  local dir="${CODEX_HOME:-$HOME/.codex}/sessions"
  [ -d "$dir" ] || return 1
  find "$dir" -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-
}

# Which agents look present on this machine, most recently used first.
agent_detect() {
  local out=""
  [ -d "$HOME/.claude/projects" ] && out="$out claude"
  [ -d "${CODEX_HOME:-$HOME/.codex}/sessions" ] && out="$out codex"
  printf '%s' "${out# }"
}

agent_newest_transcript() {             # agent_newest_transcript [cwd]
  local cwd="${1:-$PWD}" a t
  for a in $(agent_detect); do
    t=$("_agent_${a}_newest" "$cwd" 2>/dev/null) || continue
    [ -n "$t" ] && { printf '%s' "$t"; return 0; }
  done
  return 1
}

# A transcript path identifies the session. Both agents name the file after the
# session id, so this holds for either.
agent_session_id() {                    # agent_session_id <transcript>
  [ -n "${1:-}" ] || return 1
  basename "$1" .jsonl
}

# Display name for a session, when the agent records one.
agent_session_title() {                 # agent_session_title <session-id>
  local sid="${1:-}" f
  [ -n "$sid" ] || return 1
  f=$(ls -1 "$HOME"/.claude/projects/*/"$sid"/custom-title.json 2>/dev/null | head -1)
  if [ -n "$f" ] && command -v python3 >/dev/null; then
    python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("customTitle") or "")
except Exception: print("")' "$f" 2>/dev/null | grep . && return 0
  fi
  printf '%s' "${sid:0:8}"
}
