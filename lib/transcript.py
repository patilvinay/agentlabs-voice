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
              'status': status}[action](value))
    except (OSError, ValueError, KeyError) as error:
        print(f'transcript: {error}', file=sys.stderr)
        sys.exit(1)
