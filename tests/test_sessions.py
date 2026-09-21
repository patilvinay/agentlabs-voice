import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.run = self.home / 'run'
        self.run.mkdir()
        self.env = {**os.environ, 'HOME': str(self.home), 'AGENTLABS_RUN': str(self.run),
                    'TMUX_PANE': '', 'CC_TTS_CONF': '/dev/null'}

    def transcript(self, name, records):
        p = self.home / name
        p.write_text(''.join(json.dumps(r) + '\n' for r in records))
        return p

    def shell(self, code, *args):
        return subprocess.run(['bash', '-c', 'source "$1/lib/agent.sh"; ' + code,
                               'test', str(ROOT), *map(str, args)], env=self.env,
                              text=True, capture_output=True)

    def test_codex_reads_final_not_newer_commentary(self):
        p = self.transcript('codex.jsonl', [
            {'type': 'response_item', 'payload': {'type': 'message', 'role': 'assistant',
             'phase': 'final_answer', 'id': 'final-1', 'content': [{'type': 'output_text', 'text': '<voice>My session.</voice>'}]}},
            {'type': 'response_item', 'payload': {'type': 'message', 'role': 'assistant',
             'phase': 'commentary', 'content': [{'type': 'output_text', 'text': 'Working...'}]}}
        ])
        result = self.shell('agent_latest_message "$2"', p)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['text'], '<voice>My session.</voice>')

    def test_claude_parser_still_reads_text(self):
        p = self.transcript('claude.jsonl', [{'type': 'assistant', 'uuid': 'c1',
            'message': {'content': [{'type': 'text', 'text': 'Claude reply'}]}}])
        result = self.shell('agent_latest_message "$2"', p)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['text'], 'Claude reply')

    def test_codex_id_comes_from_session_metadata(self):
        p = self.transcript('rollout-dated-session.jsonl', [
            {'type': 'session_meta', 'payload': {'id': 'my-session'}}])
        result = self.shell('agent_session_id "$2"', p)
        self.assertEqual(result.stdout.strip(), 'my-session')

    def test_session_dir_prefers_own_mapping_to_neighbor(self):
        mine = self.transcript('mine.jsonl', [])
        other = self.transcript('neighbor.jsonl', [])
        (self.run / 'pane-1.transcript').write_text(str(mine))
        (self.run / 'pane-2.transcript').write_text(str(other))
        # Simulate tmux listing a neighboring agent first, without touching the user's server.
        bindir = self.home / 'bin'
        bindir.mkdir()
        tmux = bindir / 'tmux'
        tmux.write_text('#!/bin/sh\ncase "$*" in *pane_pid*) exit 1;; *list-panes*) printf "claude %%2\\nzsh %%1\\n";; *) echo test:1;; esac\n')
        tmux.chmod(0o755)
        env = {**self.env, 'PATH': str(bindir) + ':' + self.env['PATH']}
        result = subprocess.run(['bash', str(ROOT / 'bin/session-dir'), '%1'],
                                env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Path(result.stdout.strip()).name, 'mine')

    def test_unknown_pane_does_not_borrow_claude_session(self):
        p = self.home / '.claude/projects/project'
        p.mkdir(parents=True)
        (p / 'other.jsonl').write_text('{}\n')
        result = subprocess.run(['bash', str(ROOT / 'bin/session-dir'), '%999999'],
                                env=self.env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_manual_playback_uses_own_voice_and_voice_block(self):
        import shutil
        mine = self.transcript('mine.jsonl', [
            {'type': 'session_meta', 'payload': {'id': 'mine'}},
            {'type': 'response_item', 'payload': {'type': 'message', 'role': 'assistant',
             'phase': 'final_answer', 'content': [{'type': 'output_text',
             'text': 'Screen text. <voice>Only my summary.</voice>'}]}}
        ])
        (self.run / 'pane-999998.transcript').write_text(str(mine))
        voice = self.home / '.claude/scratch/mine/.voice'
        voice.parent.mkdir(parents=True)
        voice.write_text('en-GB-RyanNeural')
        hooks = self.home / 'hooks'
        hooks.mkdir()
        shutil.copy(ROOT / 'hooks/say-last.sh', hooks)
        # Replace only the audio boundary; use real routing, parsing and voice selection.
        (hooks / 'speak.sh').write_text(
            f'source "{ROOT}/hooks/speak.sh"\n'
            'tts_cancel() { :; }\n'
            'tts_speak() { tts_apply_session_voice; printf "%s\\n%s\\n" "$CC_TTS_VOICE_EDGE" "$1"; }\n')
        result = subprocess.run(['bash', str(hooks / 'say-last.sh'), '--pane', '%999998'],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'en-GB-RyanNeural\nOnly my summary.')

    def test_live_codex_overrides_stale_claude_mapping(self):
        import sys
        session = self.home / 'sessions'
        session.mkdir()
        mine = session / 'rollout.jsonl'
        mine.write_text('{}\n')
        stale = self.transcript('old-claude.jsonl', [])
        (self.run / 'pane-3.transcript').write_text(str(stale))
        child = subprocess.Popen([sys.executable, '-c',
            'import ctypes,sys; ctypes.CDLL(None).prctl(15,b"codex",0,0,0); '
            'f=open(sys.argv[1]); print("ready",flush=True); sys.stdin.read()', str(mine)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.addCleanup(child.stdout.close)
        self.addCleanup(child.stdin.close)
        self.addCleanup(child.wait)
        self.addCleanup(child.terminate)
        self.assertEqual(child.stdout.readline().strip(), 'ready')
        result = self.shell('fixture_pid="$3"; tmux() { echo "$fixture_pid"; }; agent_pane_transcript "%3"', mine, child.pid)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, str(mine))

    def test_voice_tag_mentioned_in_prose_does_not_swallow_summary(self):
        result = subprocess.run(['bash', '-c',
            'source "$1/hooks/speak.sh"; tts_resolve', 'test', str(ROOT)],
            input='I will include a `<voice>` block.\n<voice>Just this summary.</voice>',
            env=self.env, text=True, capture_output=True)
        self.assertEqual(result.stdout.strip(), 'Just this summary.')


if __name__ == '__main__':
    unittest.main()
