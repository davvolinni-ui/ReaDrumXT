# ReaDrumXT 0.1.6

## Changes

- Fixed sampler memory overlap between pad controls and pan, transient and legato state. This could bias pad audition to the right before sequencer playback.
- Improved startup acknowledgement and recovery when runtime state, transport maps or playback ownership are displaced. Runtime repair retries back off instead of continually rebuilding.
- Improved sample-rate handling and extended transport-map coverage for long-running sequencer playback.
- Corrected inherited Drive/filter handling and pad-control reset publication.
- Added read-only FX, routing, pad and bounded MIDI inventory to the diagnostic report.
- Added an optional ten-second playback capture under Settings > Support. It records note flow and voice starts, not audio, and does not start playback or change routing.
- Adjusted the compact playback row to reserve space for the Drive knob without wrapping the knobs onto another row.

## Updating and reporting problems

Save your project and restart REAPER after updating so both Lua and JSFX changes load.

For playback problems, create a diagnostic report and run Capture Playback while the problem occurs. Reports are saved under the REAPER resource folder at `Data/ReaDrumXT/Diagnostics`. Captures require the updated dispatcher and sampler engines.

## Verification limits

Focused Windows checks reproduced the old sampler memory corruption and passed with the corrected layout. English and Cyrillic sample paths were compared through sequencer and HOST MIDI playback; dispatcher and sampler counts matched for each pad.

These checks do not establish that every reported 0.1.5 playback failure is fixed. Voice-start counts do not prove audible output. Russian/Ukrainian regional settings and macOS playback have not been validated by these checks. No full release-wide regression suite was rerun for this packaging step.
