#!/usr/bin/env bash
# Which coding agent is in this pane, and where is its transcript?
#
# Sourced by both agentlabs-voice and agentlabs-ideas-skill. Everything that
# differs between Claude Code and Codex lives here, so the rest of either
# project never names an agent.
#
# Codex is identified by the rollout file open in the pane's live process.
# Claude uses its Stop-hook mapping. Transcript parsing lives in transcript.py.

agentlabs_run() {
  local uid; uid=$(id -u)
  if [ -d "/run/user/$uid" ]; then printf '/run/user/%s/agentlabs' "$uid"
  else printf '/tmp/agentlabs-%s' "$uid"; fi
}

AGENTLABS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
  local pid t rc f="$AGENTLABS_RUN/pane-${1#%}.transcript"
  pid=$(tmux display -p -t "$1" '#{pane_pid}' 2>/dev/null) || pid=""
  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    t=$(python3 "$AGENTLABS_LIB/transcript.py" pane "$pid"); rc=$?
    if [ "$rc" = 0 ]; then
      agent_remember_pane "$1" "$t"
      printf '%s' "$t"
      return 0
    fi
    [ "$rc" = 2 ] && return 1
  fi
  [ -f "$f" ] || return 1
  t=$(cat "$f"); [ -f "$t" ] || return 1
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

# Outside tmux only: Codex keeps rollout transcripts under ~/.codex/sessions, dated
# directories, one .jsonl per session. Newest wins; there is no per-directory
# split to narrow by, so this is less precise than the Claude case.
_agent_codex_newest() {                 # _agent_codex_newest <cwd>
  local dir="${CODEX_HOME:-$HOME/.codex}/sessions"
  [ -d "$dir" ] || return 1
  find "$dir" -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-
}

# Which agents have transcript stores (Claude first for the legacy fallback).
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

# Codex stores its session id in metadata; Claude names its file with the id.
agent_session_id() {                    # agent_session_id <transcript>
  [ -n "${1:-}" ] || return 1
  python3 "$AGENTLABS_LIB/transcript.py" id "$1"
}

agent_session_root() {                  # agent_session_root <transcript>
  case "${1:-}" in
    "${CODEX_HOME:-$HOME/.codex}"/sessions/*)
      printf '%s' "${CODEX_HOME:-$HOME/.codex}/scratch" ;;
    *) printf '%s' "$HOME/.claude/scratch" ;;
  esac
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
  f="${CODEX_HOME:-$HOME/.codex}/session_index.jsonl"
  if [ -f "$f" ] && command -v python3 >/dev/null; then
    python3 -c 'import json,sys
sid=sys.argv[2]; title=""
for line in open(sys.argv[1], encoding="utf-8"):
    try:
        record=json.loads(line)
        if record.get("id") == sid: title=record.get("thread_name") or title
    except Exception: pass
print(title)' "$f" "$sid" 2>/dev/null | grep . && return 0
  fi
  printf '%s' "${sid:0:8}"
}

# JSON {id,text}; Codex commentary is deliberately excluded.
agent_latest_message() {
  python3 "$AGENTLABS_LIB/transcript.py" latest "$1"
}
