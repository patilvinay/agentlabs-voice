#!/usr/bin/env python3
"""Read agent transcripts and identify a live Codex session in a tmux pane."""
import datetime
import hashlib
import re
import json
import os
from pathlib import Path
import sys


def records(path):
    with open(path) as stream:
        for line in stream:
            try:
                yield json.loads(line)
            except ValueError:
                continue  # A writer may still be flushing its last record.


def latest(path):
    result = None
    for record in records(path):
        payload = record.get('payload', {})
        if record.get('type') == 'assistant':
            content = record.get('message', {}).get('content', [])
            identity = record.get('uuid')
        elif (record.get('type') == 'response_item' and payload.get('type') == 'message'
              and payload.get('role') == 'assistant'
              and payload.get('phase') == 'final_answer'):
            content = payload.get('content', [])
            identity = payload.get('id')
        else:
            continue
        text = '\n'.join(c.get('text', '') for c in content
                         if c.get('type') in ('text', 'output_text'))
        if text.strip():
            result = {'id': identity or hashlib.sha256(json.dumps(record).encode()).hexdigest(),
                      'text': text}
    if result is None:
        return 1
    print(json.dumps(result))
    return 0


def session_id(path):
    for record in records(path):
        if record.get('type') == 'session_meta':
            identity = record.get('payload', {}).get('id')
            if identity:
                print(identity)
                return 0
        break
    print(Path(path).stem)
    return 0


def pane_transcript(pid):
    # Follow the pane's process tree, stopping at the root Codex process. Do not
    # inspect its workers/subagents, which can have their own transcripts.
    pending = [int(pid)]
    while pending:
        current = pending.pop(0)
        proc = Path('/proc') / str(current)
        try:
            if (proc / 'comm').read_text().strip() == 'codex':
                paths = set()
                for fd in (proc / 'fd').iterdir():
                    try:
                        path = os.readlink(fd)
                        if '/sessions/' in path and path.endswith('.jsonl') and Path(path).is_file():
                            paths.add(path)
                    except OSError:
                        continue
                if len(paths) == 1:
                    print(paths.pop())
                    return 0
                return 2  # Found Codex: never fall back to a stale Claude map.
            children = proc / 'task' / str(current) / 'children'
            pending.extend(int(p) for p in children.read_text().split())
        except (OSError, ValueError):
            continue
    return 1


# --- Claude Code background daemon -----------------------------------------
# A session hosted by `claude daemon` runs in a worker with no TMUX_PANE; the
# tmux pane holds only a thin client. Two Claude Code internals connect them,
# both undocumented and so read defensively (any surprise means "not found"):
#   ~/.claude/sessions/<pid>.json   per live process: sessionId, tmux
#                                   "sess:@win.%pane", and for a client
#                                   attached to a worker, parkedJobId.
#   ~/.claude/daemon/roster.json    workers[<short>] = {sessionId, dispatch:
#                                   {launch: {sessionId: <parent>}}}; a restart
#                                   relaunches the session as a fork with a new id.

MAX_FORK_DEPTH = 8


def _claude_home():
    return Path(os.environ.get('CLAUDE_CONFIG_DIR') or Path.home() / '.claude')


def _load_json(path):
    try:
        data = json.loads(Path(path).read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except PermissionError:
        return True
    except (OSError, ValueError, TypeError):
        return False


def _as_sid(value):
    # launch.sessionId is sometimes a transcript path, sometimes a bare id.
    if not isinstance(value, str) or not value:
        return None
    return Path(value).stem if value.endswith('.jsonl') else value


def _workers():
    workers = _load_json(_claude_home() / 'daemon' / 'roster.json').get('workers')
    return workers if isinstance(workers, dict) else {}


def lineage(sid):
    """The session followed by the sessions it was forked from, nearest first."""
    workers = _workers()
    chain = [sid]
    while len(chain) <= MAX_FORK_DEPTH:
        parent = None
        for worker in workers.values():
            if isinstance(worker, dict) and worker.get('sessionId') == chain[-1]:
                launch = (worker.get('dispatch') or {}).get('launch') or {}
                if isinstance(launch, dict):
                    parent = _as_sid(launch.get('sessionId'))
                break
        if not parent or parent in chain:
            break
        chain.append(parent)
    return chain


def _job_of(sid):
    for short, worker in _workers().items():
        if isinstance(worker, dict) and worker.get('sessionId') == sid:
            return short
    return None


def _clients():
    """Live Claude processes that sit in a tmux pane: (record, pane)."""
    out = []
    for f in (_claude_home() / 'sessions').glob('*.json'):
        record = _load_json(f)
        tmux = record.get('tmux')
        if not isinstance(tmux, str) or '%' not in tmux or not _alive(record.get('pid')):
            continue
        out.append((record, '%' + tmux.rsplit('%', 1)[1]))
    return out


def _live_panes():
    import subprocess
    try:
        r = subprocess.run(['tmux', 'list-panes', '-a', '-F', '#{pane_id}'],
                           capture_output=True, text=True, timeout=2)
    except (OSError, subprocess.SubprocessError):
        return None
    return set(r.stdout.split()) if r.returncode == 0 else None


def claude_pane(path):
    """Print the tmux pane showing this Claude transcript's session.

    1. A live client that says so: attached to this session's daemon job
       (parkedJobId), or running the session itself.
    2. The pane map, for this session or, failing that, the nearest session it
       was forked from — unless that pane is now running the parent itself.
    """
    sid = Path(path).stem
    clients = _clients()
    job = _job_of(sid)
    for record, pane in clients:
        if (job and record.get('parkedJobId') == job) or \
           (record.get('sessionId') == sid and not record.get('parkedJobId')):
            print(pane)
            return 0

    run = Path(os.environ.get('AGENTLABS_RUN') or '')
    if not run.is_dir():
        return 1
    live = _live_panes()
    maps = sorted(run.glob('pane-*.transcript'), key=lambda f: f.stat().st_mtime, reverse=True)
    for ancestor in lineage(sid):
        for f in maps:
            try:
                if Path(f.read_text().strip()).stem != ancestor:
                    continue
            except OSError:
                continue
            pane = '%' + f.name[len('pane-'):-len('.transcript')]
            if live is not None and pane not in live:
                continue
            if ancestor != sid and any(p == pane and r.get('sessionId') == ancestor
                                       and not r.get('parkedJobId') for r, p in clients):
                continue  # the parent is still running in that pane
            print(pane)
            return 0
    return 1


def print_lineage(sid):
    print('\n'.join(lineage(Path(sid).stem)[1:]))
    return 0


def status(path):
    """Where is this session right now? Read from the transcript so a key can
    answer instantly, without waiting for the agent to finish a tool call --
    which is exactly when you most want to ask."""
    rows = list(records(path))

    def blocks(record):
        content = record.get('message', {}).get('content')
        return [b for b in content if isinstance(b, dict)] if isinstance(content, list) else []

    # Anchor on the last thing the person said. A mid-turn steer is
    # indistinguishable from a fresh prompt in the transcript, and that is the
    # right answer anyway: "working since you last said anything".
    anchor = 0
    for i, record in enumerate(rows):
        if record.get('type') != 'user' or record.get('userType') != 'external':
            continue
        if any(b.get('type') == 'tool_result' for b in blocks(record)):
            continue
        anchor = i

    called, returned, last_tool, said = {}, set(), None, []
    for record in rows[anchor:]:
        for block in blocks(record):
            kind = block.get('type')
            if kind == 'tool_use':
                called[block.get('id')] = block.get('name')
                last_tool = block.get('name')
            elif kind == 'tool_result':
                returned.add(block.get('tool_use_id'))
            elif kind == 'text' and record.get('type') == 'assistant':
                said.append(block.get('text', ''))

    started = rows[anchor].get('timestamp') if rows else None
    latest = next((r.get('timestamp') for r in reversed(rows) if r.get('timestamp')), None)
    voiced = [v for t in said for v in re.findall(
        r'<voice>((?:(?!<voice>).)*?)</voice>', t, re.S)]

    print(json.dumps({
        'elapsed': _seconds_between(started, latest),
        'tools': len(called),
        'in_flight': len([i for i in called if i not in returned]),
        'last_tool': last_tool,
        'said': len(said),
        # The last thing meant to be heard, else the opening of the last thing
        # written. Either is more use than "it is still working".
        'last_voice': (voiced[-1].strip() if voiced else ''),
        'last_text': (said[-1].strip()[:400] if said else ''),
    }))
    return 0


def _seconds_between(start, end):
    if not (start and end):
        return 0
    try:
        fmt = '%Y-%m-%dT%H:%M:%S'
        a = datetime.datetime.strptime(start[:19], fmt)
        b = datetime.datetime.strptime(end[:19], fmt)
        return max(0, int((b - a).total_seconds()))
    except ValueError:
        return 0


if __name__ == '__main__':
    try:
        action, value = sys.argv[1:]
        sys.exit({'latest': latest, 'id': session_id, 'pane': pane_transcript,
              'status': status, 'claude-pane': claude_pane,
              'lineage': print_lineage}[action](value))
    except (OSError, ValueError, KeyError) as error:
        print(f'transcript: {error}', file=sys.stderr)
        sys.exit(1)
