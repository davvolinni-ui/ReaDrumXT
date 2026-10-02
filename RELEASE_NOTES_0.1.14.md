# ReaDrumXT 0.1.14

## Changes

- Project state now uses checksummed, staged saves with a redundant folder-track copy, improving recovery and keeping saved pad settings and patterns in sync.
- Reopening projects restores authoritative sampler assignments and controls, reloads rebound banks, and clears unused slots.
- Open projects reserve separate engine namespaces and snapshot storage to prevent playback state collisions.
- Managed track folder repairs preserve enclosing user folders and correctly close racks without AUX returns.
- Settings now offers a default pad fader level of -6 dB, -3 dB, or 0 dB for new racks. Existing projects and kits retain their levels.

## Updating

Save your project and restart ReaDrumXT after updating.
