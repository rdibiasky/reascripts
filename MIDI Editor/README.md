# MIDI Editor

Scripts for working with notes in the REAPER MIDI editor.

## Utilities

### Distribute MIDI notes evenly

Evenly spaces the start positions of the selected notes in the active MIDI
editor. The first and last notes keep their original start positions; the
intermediate notes are placed at equal intervals between them.

- Preserves each note's duration, channel, pitch, velocity, mute state, and
  selection state.
- Modifies selected notes only.
- Makes no changes if there is no active MIDI editor or fewer than two notes
  are selected.
- Notes keep their original durations, so they may overlap after distribution.

To use it, open the MIDI editor, select at least two notes, and run
**Distribute MIDI notes evenly** from REAPER's Actions list. The operation is
recorded in the undo history.
