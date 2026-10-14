# ReaDrumXT 0.1.15

## Changes

- Adds project sample collection with verified, deduplicated copies and project-relative references for sharing a project folder.
- Resolves collected samples when reopening a project on another computer, while preserving absolute references for foreign kits and copied pads.
- Keeps original sample references when collection is cancelled, verification fails, or the engine cannot commit the change.
- Adds waveform zoom and pan with pointer-anchored zoom, bounded navigation, and accurate trim-handle coordinates.
- Improves envelope value display without changing saved controls during waveform navigation.

## Updating

Save your project and restart ReaDrumXT after updating. To share collected samples, share the complete project folder; the recipient should launch ReaDrumXT once and save the project.

## Validation

- Core and regression suite: 146/146 passed.
