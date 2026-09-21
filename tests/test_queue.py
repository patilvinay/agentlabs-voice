"""The utterance queue: ordering, per-entry voice, skip and stop.

Playback is switched off with CC_TTS_ENGINE=off, so these exercise the queue
itself rather than the synthesiser.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.run = self.home / 'run'
        self.run.mkdir()
        self.env = {**os.environ,
                    'HOME': str(self.home),
                    'CC_TTS_RUN': str(self.run),
                    'CC_TTS_CONF': '/dev/null',
                    'CC_TTS_ENGINE': 'off',
                    'CC_TTS_DEBUG': '0',
                    'TMUX_PANE': ''}

    def sh(self, script):
        return subprocess.run(
            ['bash', '-c', f'. "{ROOT}/hooks/speak.sh"\n{script}'],
            env=self.env, capture_output=True, text=True, timeout=30)

    def entries(self):
        return sorted(p.name for p in (self.run / 'queue').glob('*.utt'))

    # --- ordering -----------------------------------------------------------

    def test_entries_are_spoken_in_arrival_order(self):
        out = self.sh('''
            tts_kick() { :; }                    # drain by hand, deterministically
            tts_enqueue "first"; tts_enqueue "second"; tts_enqueue "third"
            tts_say() { printf '%s\\n' "$1"; }
            tts_drain_loop
        ''')
        self.assertEqual(out.stdout.split(), ['first', 'second', 'third'], out.stderr)

    def test_front_jumps_the_queue(self):
        out = self.sh('''
            tts_kick() { :; }
            tts_enqueue "narration"; tts_enqueue "more narration"
            tts_enqueue --front "permission please"
            tts_say() { printf '%s\\n' "$1"; }
            tts_drain_loop
        ''')
        self.assertEqual(out.stdout.splitlines()[0], 'permission please', out.stderr)

    # --- the voice travels with the text ------------------------------------

    def test_entry_carries_the_voice_it_was_queued_with(self):
        """Sessions pick their own voice; the drainer must not use whichever
        one happened to be set when it got there."""
        out = self.sh('''
            tts_kick() { :; }
            CC_TTS_VOICE_EDGE=voice-A tts_enqueue "from A"
            CC_TTS_VOICE_EDGE=voice-B tts_enqueue "from B"
            CC_TTS_VOICE_EDGE=voice-Z
            tts_say() { printf '%s:%s\\n' "$CC_TTS_VOICE_EDGE" "$1"; }
            tts_drain_loop
        ''')
        self.assertEqual(out.stdout.splitlines(),
                         ['voice-A:from A', 'voice-B:from B'], out.stderr)

    # --- leaving an utterance -----------------------------------------------

    def test_stop_drops_everything_still_queued(self):
        out = self.sh('''
            tts_kick() { :; }
            tts_enqueue "one"; tts_enqueue "two"; tts_enqueue "three"
            # Speaking the first sets the stop flag, as prefix+V would.
            tts_say() { printf '%s\\n' "$1"; : > "$cc_tts_qstop"; }
            tts_drain_loop
            printf 'left=%s\\n' "$(tts_queue_depth)"
        ''')
        self.assertEqual(out.stdout.split(), ['one', 'left=0'], out.stderr)

    def test_skip_leaves_the_rest_of_the_queue_alone(self):
        """tts_cancel is a skip: no stop flag, so the drainer carries on."""
        out = self.sh('''
            tts_kick() { :; }
            tts_enqueue "one"; tts_enqueue "two"; tts_enqueue "three"
            tts_say() { printf '%s\\n' "$1"; tts_cancel; }
            tts_drain_loop
            printf 'left=%s\\n' "$(tts_queue_depth)"
        ''')
        self.assertEqual(out.stdout.split(), ['one', 'two', 'three', 'left=0'], out.stderr)

    def test_entry_is_removed_before_it_is_spoken(self):
        """A crash in the synthesiser must not leave an entry to replay forever."""
        out = self.sh('''
            tts_kick() { :; }
            tts_enqueue "boom"
            tts_say() { printf 'depth=%s\\n' "$(tts_queue_depth)"; }
            tts_drain_loop
        ''')
        self.assertEqual(out.stdout.strip(), 'depth=0', out.stderr)

    def test_a_stale_stop_flag_does_not_truncate_the_next_batch(self):
        """prefix+V with nothing playing leaves the flag behind: no drainer is
        running to consume it. Queueing again must clear it."""
        out = self.sh('''
            tts_kick() { :; }
            tts_stop_all                          # as prefix+V, nothing playing
            [ -f "$cc_tts_qstop" ] && echo "flag-set"
            tts_enqueue "one"; tts_enqueue "two"
            tts_say() { printf '%s\\n' "$1"; }
            tts_drain_loop
        ''')
        self.assertEqual(out.stdout.split(), ['flag-set', 'one', 'two'], out.stderr)

    # --- empty queue --------------------------------------------------------

    def test_blank_text_is_not_queued(self):
        out = self.sh('tts_kick() { :; }; tts_enqueue ""; tts_enqueue "   "; tts_queue_depth')
        self.assertEqual(out.stdout.strip(), '1', out.stderr)  # "   " is not blank


if __name__ == '__main__':
    unittest.main()
