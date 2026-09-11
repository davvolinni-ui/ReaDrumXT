# ReaDrumXT 0.1.9

## Changes

- Fixed sequencer timing becoming displaced or remaining on the previous tempo after changing REAPER's tempo during playback. ReaDrumXT now rebases the dispatcher schedule after publishing the updated transport map.
- Fixed copied patterns and variations being lost when switching between REAPER project tabs before pasting.

## Updating

Save your project and restart ReaDrumXT after updating.

ReaDrumXT must remain open while editing the project tempo so it can publish REAPER's updated tempo map to the playback engine.
