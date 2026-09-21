"""prefix+u reads the transcript: elapsed, tool counts, what is in flight."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class StatusTests(unittest.TestCase):
    def status(self, rows):
        with tempfile.NamedTemporaryFile('w', suffix='.jsonl', delete=False) as f:
            for row in rows:
                f.write(json.dumps(row) + '\n')
            path = f.name
        out = subprocess.run(['python3', str(ROOT / 'lib/transcript.py'), 'status', path],
                             capture_output=True, text=True, timeout=20)
        self.assertEqual(out.returncode, 0, out.stderr)
        return json.loads(out.stdout)

    @staticmethod
    def prompt(text, ts):
        return {'type': 'user', 'userType': 'external', 'message': {'content': text},
                'timestamp': ts}

    @staticmethod
    def call(tid, name, ts):
        return {'type': 'assistant', 'timestamp': ts, 'message': {'content': [
            {'type': 'tool_use', 'id': tid, 'name': name}]}}

    @staticmethod
    def result(tid, ts):
        return {'type': 'user', 'userType': 'external', 'timestamp': ts, 'message': {
            'content': [{'type': 'tool_result', 'tool_use_id': tid}]}}

    @staticmethod
    def says(text, ts):
        return {'type': 'assistant', 'timestamp': ts, 'message': {'content': [
            {'type': 'text', 'text': text}]}}

    def test_reports_an_unreturned_call_as_in_flight(self):
        s = self.status([
            self.prompt('go', '2026-09-21T10:00:00.000Z'),
            self.call('a', 'Bash', '2026-09-21T10:00:05.000Z'),
            self.result('a', '2026-09-21T10:00:09.000Z'),
            self.call('b', 'Read', '2026-09-21T10:02:00.000Z'),
        ])
        self.assertEqual((s['tools'], s['in_flight'], s['last_tool']), (2, 1, 'Read'))
        self.assertEqual(s['elapsed'], 120)

    def test_a_returned_call_is_not_in_flight(self):
        s = self.status([
            self.prompt('go', '2026-09-21T10:00:00.000Z'),
            self.call('a', 'Bash', '2026-09-21T10:00:05.000Z'),
            self.result('a', '2026-09-21T10:00:09.000Z'),
        ])
        self.assertEqual(s['in_flight'], 0)

    def test_counting_restarts_at_the_last_thing_the_person_said(self):
        """A mid-turn steer is indistinguishable from a fresh prompt, and that
        is the right anchor: "working since you last said anything"."""
        s = self.status([
            self.prompt('first', '2026-09-21T09:00:00.000Z'),
            self.call('a', 'Bash', '2026-09-21T09:00:01.000Z'),
            self.result('a', '2026-09-21T09:00:02.000Z'),
            self.prompt('actually, status?', '2026-09-21T10:00:00.000Z'),
            self.call('b', 'Read', '2026-09-21T10:00:30.000Z'),
        ])
        self.assertEqual((s['tools'], s['elapsed']), (1, 30))

    def test_a_tool_result_is_never_mistaken_for_a_prompt(self):
        """Tool results arrive as user records; anchoring on one would reset
        the clock on every single tool call."""
        s = self.status([
            self.prompt('go', '2026-09-21T10:00:00.000Z'),
            self.call('a', 'Bash', '2026-09-21T10:00:05.000Z'),
            self.result('a', '2026-09-21T10:05:00.000Z'),
        ])
        self.assertEqual((s['tools'], s['elapsed']), (1, 300))

    def test_prefers_the_last_voice_block_over_the_surrounding_reply(self):
        s = self.status([
            self.prompt('go', '2026-09-21T10:00:00.000Z'),
            self.says('Screen text nobody needs read out. <voice>The short one.</voice>',
                      '2026-09-21T10:00:10.000Z'),
        ])
        self.assertEqual(s['last_voice'], 'The short one.')
        self.assertEqual(s['said'], 1)

    def test_falls_back_to_the_reply_when_nothing_was_written_for_the_ear(self):
        s = self.status([
            self.prompt('go', '2026-09-21T10:00:00.000Z'),
            self.says('No voice block here.', '2026-09-21T10:00:10.000Z'),
        ])
        self.assertEqual(s['last_voice'], '')
        self.assertEqual(s['last_text'], 'No voice block here.')

    def test_a_turn_that_has_not_started_reports_nothing_rather_than_failing(self):
        s = self.status([self.prompt('go', '2026-09-21T10:00:00.000Z')])
        self.assertEqual((s['tools'], s['in_flight'], s['said'], s['last_tool']),
                         (0, 0, 0, None))


if __name__ == '__main__':
    unittest.main()
