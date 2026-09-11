# ReaDrumXT 0.1.8

## Changes

- Fixed random and random-no-repeat round-robin playback consuming an extra random draw at 0% or 100% group probability.
- Fixed ReaDrumXT continuing to schedule at the project's original tempo after REAPER's base BPM changed.
- Fixed high-tempo transport-map updates being rejected when a large audio block spans more than one quarter note.
- Fixed pad transpose and fine-tune controls becoming trapped below zero when adjusted upward with the mouse wheel.

## Updating

Save your project and restart REAPER after updating so both Lua and JSFX changes are loaded.

ReaDrumXT is currently focused on bug fixes, stability and compatibility. New workflow features are not part of the active development scope.
