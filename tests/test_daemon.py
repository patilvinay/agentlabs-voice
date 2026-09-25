"""Sessions hosted by `claude daemon`: no TMUX_PANE, pane found another way."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

NEW = 'bbbbbbbb-0000-0000-0000-000000000002'
MID = 'aaaaaaaa-0000-0000-0000-000000000001'
OLD = '99999999-0000-0000-0000-000000000000'


class DaemonPaneTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.run = self.home / 'run'
        self.run.mkdir()
        self.claude = self.home / '.claude'
        self.project = self.claude / 'projects' / '-work'
        self.project.mkdir(parents=True)
        # tmux knows panes %7 and %9 only; never ask the user's real server.
        bindir = self.home / 'bin'
        bindir.mkdir()
        tmux = bindir / 'tmux'
        tmux.write_text('#!/bin/sh\ncase "$*" in *list-panes*) printf "%%7\\n%%9\\n";; *) exit 1;; esac\n')
        tmux.chmod(0o755)
        self.env = {**os.environ, 'HOME': str(self.home), 'AGENTLABS_RUN': str(self.run),
                    'PATH': f'{bindir}:{os.environ["PATH"]}', 'TMUX_PANE': '',
                    'CC_TTS_CONF': '/dev/null', 'CC_TTS_RUN': str(self.home / 'ttsrun'),
                    'CC_TTS_ENGINE': 'off', 'CC_TTS_DEBUG': '0'}
        self.env.pop('CLAUDE_CONFIG_DIR', None)
        self.env.pop('TMUX', None)

    def transcript(self, sid):
        p = self.project / f'{sid}.jsonl'
        p.write_text('{}\n')
        return p

    def roster(self, *forks):
        """forks: (child, parent) pairs, as the daemon records a resume-fork."""
        workers = {child[:8]: {'sessionId': child, 'pid': 1,
                               'dispatch': {'launch': {'mode': 'resume', 'fork': True,
                                   'sessionId': str(self.project / f'{parent}.jsonl')}}}
                   for child, parent in forks}
        d = self.claude / 'daemon'
        d.mkdir(exist_ok=True)
        (d / 'roster.json').write_text(json.dumps({'proto': 1, 'workers': workers}))

    def client(self, pane, **record):
        d = self.claude / 'sessions'
        d.mkdir(exist_ok=True)
        pid = os.getpid()  # alive for the duration of the test
        (d / f'{pid}.json').write_text(json.dumps({'pid': pid, 'kind': 'interactive',
                                                   'tmux': f'0:@1.{pane}', **record}))

    def pane_map(self, pane, transcript):
        (self.run / f'pane-{pane}.transcript').write_text(str(transcript))

    def resolve(self, transcript):
        return subprocess.run(['bash', '-c', 'source "$1/lib/agent.sh"; agent_pane_for_transcript "$2"',
                               'test', str(ROOT), str(transcript)],
                              env=self.env, text=True, capture_output=True)

    def test_direct_map_hit(self):
        t = self.transcript(NEW)
        self.pane_map(7, t)
        self.assertEqual(self.resolve(t).stdout, '%7')

    def test_client_attached_to_daemon_job(self):
        t = self.transcript(NEW)
        self.roster((NEW, OLD))
        self.client('%9', sessionId=OLD, parkedJobId=NEW[:8])
        self.assertEqual(self.resolve(t).stdout, '%9')
        self.assertEqual((self.run / 'pane-9.transcript').read_text(), str(t))

    def test_lineage_hit_rewrites_stale_map(self):
        old, new = self.transcript(OLD), self.transcript(NEW)
        self.roster((NEW, OLD))
        self.pane_map(9, old)
        self.assertEqual(self.resolve(new).stdout, '%9')
        self.assertEqual((self.run / 'pane-9.transcript').read_text(), str(new))

    def test_two_level_fork_chain(self):
        old, new = self.transcript(OLD), self.transcript(NEW)
        self.transcript(MID)
        self.roster((NEW, MID), (MID, OLD))
        self.pane_map(7, old)
        self.assertEqual(self.resolve(new).stdout, '%7')

    def test_no_roster_does_not_borrow_another_sessions_pane(self):
        old, new = self.transcript(OLD), self.transcript(NEW)
        self.pane_map(9, old)
        result = self.resolve(new)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.run / 'pane-9.transcript').read_text(), str(old))

    def test_parent_still_running_in_its_pane_is_not_taken(self):
        old, new = self.transcript(OLD), self.transcript(NEW)
        self.roster((NEW, OLD))
        self.pane_map(9, old)
        self.client('%9', sessionId=OLD)
        self.assertNotEqual(self.resolve(new).returncode, 0)

    def test_dead_pane_is_skipped(self):
        new = self.transcript(NEW)
        self.pane_map(5, new)  # tmux does not list %5
        self.assertNotEqual(self.resolve(new).returncode, 0)

    def test_malformed_roster_falls_back_silently(self):
        new = self.transcript(NEW)
        (self.claude / 'daemon').mkdir()
        (self.claude / 'daemon' / 'roster.json').write_text('{"workers": [1, 2')
        result = self.resolve(new)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr, '')

    def stop_hook(self, transcript, **env):
        return subprocess.run(['bash', str(ROOT / 'hooks/speak-last.sh')],
                              input=json.dumps({'transcript_path': str(transcript)}),
                              env={**self.env, 'CC_TTS_AUTO': '0', 'CC_TTS_OFFER': '0', **env},
                              text=True, capture_output=True)

    def test_stop_hook_without_pane_never_writes_empty_map(self):
        new = self.transcript(NEW)
        result = self.stop_hook(new)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.run / 'pane-.transcript').exists())
        self.assertEqual(list(self.run.glob('pane-*')), [])

    def test_stop_hook_remaps_pane_and_carries_identity_over(self):
        old, new = self.transcript(OLD), self.transcript(NEW)
        self.roster((NEW, OLD))
        self.pane_map(9, old)
        scratch = self.claude / 'scratch' / OLD
        scratch.mkdir(parents=True)
        (scratch / '.auto').write_text('1')
        (self.project / OLD).mkdir()
        (self.project / OLD / 'custom-title.json').write_text('{"customTitle": "hrms-dev"}')

        result = self.stop_hook(new)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.run / 'pane-9.transcript').read_text(), str(new))
        self.assertEqual((self.claude / 'scratch' / NEW / '.auto').read_text(), '1')
        self.assertEqual(json.loads((self.project / NEW / 'custom-title.json').read_text()),
                         {'customTitle': 'hrms-dev'})

    def test_empty_scaffold_is_replaced_by_parent_folder(self):
        new = self.transcript(NEW)
        self.transcript(OLD)
        self.roster((NEW, OLD))
        parent = self.claude / 'scratch' / OLD
        (parent / 'work').mkdir(parents=True)
        own = self.claude / 'scratch' / NEW
        for d in ('00-scratch', '10-review', '20-approved'):
            (own / d).mkdir(parents=True)
        (self.project / NEW).mkdir()  # title already carried over
        (self.project / NEW / 'custom-title.json').write_text('{}')
        subprocess.run(['bash', '-c', 'source "$1/lib/agent.sh"; agent_carry_over "$2"',
                        'test', str(ROOT), str(new)], env=self.env, check=True)
        self.assertTrue(own.is_symlink())
        self.assertTrue((own / 'work').is_dir())

    def test_carry_over_never_overwrites(self):
        new = self.transcript(NEW)
        self.transcript(OLD)
        self.roster((NEW, OLD))
        (self.claude / 'scratch' / OLD).mkdir(parents=True)
        own = self.claude / 'scratch' / NEW
        (own / '00-scratch').mkdir(parents=True)
        (own / '00-scratch' / 'draft.md').write_text('mine')
        subprocess.run(['bash', '-c', 'source "$1/lib/agent.sh"; agent_carry_over "$2"',
                        'test', str(ROOT), str(new)], env=self.env, check=True)
        self.assertFalse(own.is_symlink())
        self.assertEqual((own / '00-scratch' / 'draft.md').read_text(), 'mine')


if __name__ == '__main__':
    unittest.main()
