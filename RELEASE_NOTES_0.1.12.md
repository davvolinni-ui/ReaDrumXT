# ReaDrumXT 0.1.12

## Changes

- Improved transport starts, loop wraps, and host beat realignment so opening steps are recovered at the correct audio-block boundary without scanning stale scheduling history.
- Improved slide and glide handoffs by preserving slide intent through the dispatcher and adding a one-tick overlap when a preceding note ends exactly at the slide boundary.
- ReaDrumXT now reconstructs deleted managed engine tracks from the saved rack model instead of retaining invalid REAPER track pointers.
- Rebound sampler banks now invalidate stale slot generations so samples are correctly replaced when a reconstructed track reconnects to a new mailbox.

## Updating

Save your project and restart ReaDrumXT after updating.
