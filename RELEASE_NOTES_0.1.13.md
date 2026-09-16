# ReaDrumXT 0.1.13

## Changes

- Pad audition responds immediately even when the visible MIDI track is unarmed or monitoring is off. Hidden sampler workers remain active without recording, so pad clicks do not queue up for later playback.
- New visible MIDI tracks follow the user's REAPER track defaults for record arm and monitoring.
- AUX A and AUX B tracks are created when their sends or FX chains are used, keeping unused buses out of the project.
- Ctrl-drag across the step grid clears steps and their stored settings. The Repeat editor now matches the engine's 16-repeat limit.
- MIDI input follows the played pad only while this rack's MIDI track is armed, avoiding a stale note from another instrument changing the selected pad.

## Updating

Save your project and restart ReaDrumXT after updating.
