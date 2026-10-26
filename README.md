# rdibiasky ReaScripts

Collection of Lua scripts for [REAPER](https://www.reaper.fm/),
organized by category and installable with [ReaPack](https://reapack.com/).

## Installing with ReaPack

1. In REAPER, open **Extensions > ReaPack > Import a repository**.
2. Paste the index URL:

   ```text
   https://raw.githubusercontent.com/rdibiasky/reascripts/main/index.xml
   ```

3. Open **Extensions > ReaPack > Browse packages**, search for `rdibiasky`, and
   select the scripts you want to install.
4. Confirm the installation. To check for updates, run **Extensions > ReaPack >
   Synchronize packages**.

Installed scripts appear in **Actions > Show action list**. To run one, select
it and click **Run**. You can also assign it to a keyboard shortcut or
toolbar.

## Scripts

### MIDI Editor

- **Distribute MIDI notes evenly** — evenly spaces the start positions of
  selected MIDI notes in the active MIDI editor, preserving each note's
  duration and other properties.

### Utilities

- **Visual Pedalboard** — a graphical surface for controlling track
  effect parameters. Configure cells to monitor and toggle FX parameters; the
  configuration is saved in the project. Requires **ReaImGui 0.10 or later**,
  available through ReaPack.

See the [Visual Pedalboard guide](Utilities/Visual%20Pedalboard/README.md) for
usage instructions.

## Manual installation

If you prefer not to use ReaPack, copy the script's Lua file to a folder inside
REAPER's **Scripts** directory. Open that directory from **Options > Show
REAPER resource path**. Then, in **Actions > Show action list**, choose **New
action > Load ReaScript** and select the file.

## Repository structure

```text
MIDI Editor/              Scripts for the MIDI editor
Utilities/                General-purpose tools
index.xml                 ReaPack package index
generate-index.bat        Official index generator
generate-index-local.ps1  Local index generator for Windows
```

The index is served from the `main` branch. When publishing new or updated
scripts, update `index.xml` so ReaPack can discover the corresponding
versions.

### Generating the index

The official method is `reapack-index`. On Windows, run `generate-index.bat`
from File Explorer or a terminal. You can also run the command directly from
the repository root:

```powershell
reapack-index --name 'Randall Dibiasky Scripts'
```

This method requires Ruby and the `reapack-index` gem (`gem install
reapack-index`). Commit your changes to Git before indexing the published
scripts.

As a local alternative on Windows, run `.\generate-index-local.ps1` from
PowerShell. The script reads the `@description`, `@version`, and `@author`
metadata from each Lua ReaScript, uses the parent folder as its category,
uses the file's local modification date as the version date, and generates
`index.xml` without Ruby or `reapack-index`. It requires Git, a local commit,
and a GitHub `origin` remote.

The generator includes local files even if they have not been committed yet,
preserves previous index versions, and points the source URLs to the `main`
branch. It does not create commits or publish changes. For ReaPack to download
the scripts, publish the files and generated `index.xml` to GitHub.