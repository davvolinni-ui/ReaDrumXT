# ReaDrumXT 0.1.10

## Changes

- Live pattern playback now follows REAPER's native audio-block beat clock instead of a tempo map published by the Lua interface. This removes the fixed startup displacement and keeps playback aligned across project tempos.
- Round-robin members are now selected only when a note enters the current audio block. Future scheduled hits retain their source-pad intent, preventing a predictable first-step omission after repeated loop cycles.
- Lowering the project tempo during playback now rebases timing-derived scheduler state without resetting round-robin position or active-note ownership.

## Updating

Save your project and restart ReaDrumXT after updating.
