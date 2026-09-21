#!/usr/bin/env bash
# The queue drainer. Only ever run under flock, by tts_kick — running it
# directly would let two drainers fight over the audio device.
. "$(dirname "$0")/speak.sh"
tts_drain_loop
