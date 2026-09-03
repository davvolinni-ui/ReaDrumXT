# ReaDrumXT

ReaDrumXT is a drum sampler and polymetric step sequencer for REAPER on Windows.
It combines integrated sample editing, per-lane sequencing, MIDI groove
support, velocity and timing tools, round-robin playback, multi-output routing,
native REAPER track integration, and editable MIDI export.

## Installation with ReaPack

1. Install [ReaPack](https://reapack.com/) and
   [ReaImGui](https://github.com/cfillion/reaimgui).
2. In REAPER, open **Extensions > ReaPack > Import repositories**.
3. Import:

   `https://raw.githubusercontent.com/davvolinni-ui/ReaDrumXT/main/index.xml`

4. Browse for **ReaDrumXT**, install it, and restart REAPER if requested.
5. Run **ReaDrumXT - Drum Sampler and Polymetric Step Sequencer** from REAPER's
   Action List.

ReaDrumXT requires REAPER and ReaImGui. Optional SWS and JS_ReaScriptAPI features
use guarded fallbacks when those extensions are unavailable.

## Grooves

MIDI groove files are discovered recursively from
`REAPER/Data/ReaDrum/Grooves`. Subfolders become browser categories. Groove
files are user content and are not included with ReaDrumXT.

## Platform support

ReaDrumXT currently supports Windows only. macOS and Linux are not supported or
verified in this release.

## License and support

Use is governed by the included [EULA](ReaDrum/EULA.md). Third-party runtime
requirements and acknowledgements are listed in
[Third-Party Notices](ReaDrum/THIRD_PARTY_NOTICES.md).

Support and feedback: [Cockos forum thread](https://forum.cockos.com/showthread.php?t=310870)
