"""prefix+M mutes one session: the gates see its .mute file, other sessions do not."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MuteTests(unittest.TestCase):
    def muted(self, sessions, transcript):
        env = dict(os.environ, AGENTLABS_SESSIONS=sessions, CC_TTS_TRANSCRIPT='')
        sh = f'. "{ROOT}/hooks/speak.sh"; tts_session_muted "{transcript}"'
        return subprocess.run(['bash', '-c', sh], env=env, timeout=20).returncode == 0

    def test_only_the_muted_session_is_muted(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / 'aaaa-1111').mkdir()
            (Path(d) / 'aaaa-1111' / '.mute').touch()
            (Path(d) / 'proj').mkdir()
            for name in ('aaaa-1111', 'bbbb-2222'):
                (Path(d) / 'proj' / f'{name}.jsonl').write_text('{}\n')
            self.assertTrue(self.muted(d, f'{d}/proj/aaaa-1111.jsonl'))
            self.assertFalse(self.muted(d, f'{d}/proj/bbbb-2222.jsonl'))


if __name__ == '__main__':
    unittest.main()
