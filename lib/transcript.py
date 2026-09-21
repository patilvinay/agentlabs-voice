#!/usr/bin/env python3
"""Read agent transcripts and identify a live Codex session in a tmux pane."""
import hashlib
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


if __name__ == '__main__':
    try:
        action, value = sys.argv[1:]
        sys.exit({'latest': latest, 'id': session_id, 'pane': pane_transcript}[action](value))
    except (OSError, ValueError, KeyError) as error:
        print(f'transcript: {error}', file=sys.stderr)
        sys.exit(1)
