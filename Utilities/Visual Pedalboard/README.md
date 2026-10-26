# REAPER Visual Pedalboard

A live FX control surface implemented as a single Lua ReaScript using
ReaImGui. Each cell follows a manually selected parameter of an FX on a track:
green is active, red is bypassed, and gray indicates an unassigned, invalid, or
unsupported selection. Choose the plugin's own bypass parameter to control its
internal bypass; clicking a configured cell toggles the selected parameter and
creates an undo point.

## Install

1. In REAPER, install **ReaImGui 0.10 or newer** from ReaPack (Extensions >
   ReaPack > Browse packages). The script imports the versioned `imgui` API
   from ReaImGui's built-in module path with `require 'imgui' '0.10'`.
   Restart REAPER if the package manager requests it.
2. Save `rdibiasky_Visual Pedalboard.lua` somewhere under REAPER's Scripts
   directory. The exact directory is available from Options > Show REAPER
   resource path.
3. Open Actions > Show action list, choose **New action > Load ReaScript**, and
   select the Lua file. Run the new action to open the pedalboard.
4. Optionally add the action to a toolbar or assign a keyboard shortcut.

## Use

- The initial layout is a 2 x 4 grid of unassigned cells. Click any configured
  cell to toggle its selected parameter between its normalized minimum and
  maximum. The cell color updates on the next refresh (100 ms by default);
  external FX changes are detected too.
- Right-click a cell to open its configuration modal. You can also choose a
  cell number directly. Select a track, choose one of its loaded FX, then
  choose the plugin parameter that controls its internal bypass. Set a label,
  optional Active and Bypassed RGB colors with the color pickers (use
  **Default** to restore the built-in color), and an optional tooltip. Press
  **Save cell changes** to commit.
- Tracks and FX are identified by REAPER GUIDs, not list positions, so
  reordering tracks or FX does not change assignments. Deleted or unavailable
  tracks and FX are shown as invalid instead of being accessed. The selected
  parameter is resolved by its plugin-provided identifier when available.
  Periodic state checks use cached track and FX references, validating them
  before use and resolving them again only when they are no longer valid.
- Optional performance diagnostics are available under **Help > Debug mode**.
  They print a summary to REAPER's ReaScript console every five seconds,
  including frame and refresh timings, cache/search counts, playback state,
  armed/monitored track counts, and window/grid size. While debug mode is on,
  **Help > Isolation tests** can pause state reads or hide the pedalboard grid
  to compare their impact on live input monitoring. Debug mode and these test
  switches are off by default and are not saved in the project configuration.
- **Reset selected cell** clears its assignment and restores its default label.
  Open **Settings** from the menu bar to change rows, columns, cell size,
  spacing, font size, and polling interval.
  **Minimal GUI** keeps the colored, clickable cells but uses ReaImGui's native
  button labels instead of the custom multi-line text and drawing overlays.
  This can reduce rendering work; it is off by default and saved per project.
  Use **Save configuration** to persist display changes.
- **Help > Documentation** opens the usage guide. **About...** shows the
  application credit.
- Use **File > Import configuration** to replace the current project's
  configuration from a JSON file, or **File > Export configuration** to write
  the current configuration as JSON. Imported settings are validated before
  they replace the current configuration.
- **Save current dock** remembers the current dock location when REAPER exposes
  that ReaImGui API. Docking and floating are also managed by REAPER's window
  docking interface.

Configuration is stored in the current REAPER project and included in its
`.rpp` file when you save the project. Each project has its own pedalboard
configuration. Cell edits and imports are written to the project immediately;
use **Save configuration** in Settings to write display changes immediately.
Closing the script also writes the current configuration. Project settings and
JSON exports use the same compact format; empty and default-valued fields are
omitted and restored from built-in defaults when absent. Existing project
configurations saved in the previous format are not migrated and load as
defaults.

JSON exports can be imported into another project. Export opens a save-file
dialog when the JS_ReaScriptAPI extension is installed; otherwise, enter the
full destination path when prompted. Save the project after configuration
changes to persist them in its `.rpp` file.
