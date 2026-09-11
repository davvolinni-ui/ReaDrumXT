# ReaDrumXT 0.1.7

## Changes

- Fixed sequencer lanes falling silent when their timing, division, length or phase was edited during playback. The dispatcher now rebases affected lane clocks at the playhead.
- Fixed REAPER silence auto-bypass stopping the dispatcher even though it still needed to process MIDI and shared runtime state.
- Made round-robin playback order deterministic from the pad grid. Any member pad can trigger its group, while the first pad in grid order defines the sequence origin.
- Added batch sample loading through the project bridge so multiple incoming files can be distributed from the target pad.
- Preserved access to pad sound-shaping controls at shorter window heights by collapsing optional waveform regions first.
- Simplified pitch detection to a consistent Shift-click gesture that detects the sample pitch and snaps it to C, including in the docked instrument view.

## Updating

Save your project and restart REAPER after updating so both Lua and JSFX changes are loaded.

ReaDrumXT is currently focused on bug fixes, stability and compatibility. New workflow features are not part of the active development scope.
