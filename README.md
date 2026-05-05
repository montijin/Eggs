# Eggs — Notorious Monster tracker and timer for Ashita v4

**Author:** MNT  
**Version:** 1.0  
**License:** MIT  

An Ashita v4 addon for tracking Notorious Monster placeholders and respawn timers in Final Fantasy XI. Eggs monitors placeholder mob deaths, tracks respawn countdowns, and alerts you when an NM window opens or a PH respawns through time of death tracking.

---

## Features

- **PH Detection** — Automatically detects when you target a placeholder mob and shows a popup with the NM name, type, and spawn chance
- **Three UI Windows:**
  1. **Tracker** — All your tracked NMs with live countdown timers and window status
  2. **PH Detail** — Per-NM placeholder list showing which PHs are dead/alive with respawn timers
  3. **PH Popup** — Auto-appears when targeting any placeholder mob (even untracked NMs)
- **NM Browser** — Zone-grouped checklist with search to pick which NMs to track
- **Three NM Types Supported:**
  - `Timed Lottery` — Spawns off PH death with a % chance; has a cooldown after its own death
  - `True Lottery` — Same as Timed Lottery but no cooldown; can pop immediately after dying
  - `Timed Spawn` — No placeholder; respawns after a set time window after death
- **Alarm System** — Configurable `.wav` alarms with multiple sounds and early-warning timer
- **Session Persistence** — Timers survive game restarts using real-world timestamps

---

## Installation

1. Copy the `eggs` folder to `Ashita/addons/eggs/`
2. Load in-game:
   ```
   /addon load eggs
   ```

---

## Setup: Importing NM Data

Eggs reads NM data from the LandSandBird (LSB) server scripts. You need to run this once (and again whenever your LSB scripts are updated).

1. Open `Ashita/addons/eggs/import.lua`
2. Edit the `ZONES_PATH` variable at the top to point to your LSB scripts:
   ```lua
   local ZONES_PATH = 'C:\\LandSandBird\\server\\scripts\\zones';
   ```
3. In-game, run:
   ```
   /eggs import
   ```
   This scans all zone mob scripts and generates data files in `addons/eggs/data/`. It may take 10–30 seconds depending on your hardware.

---

## Commands

| Command | Description |
|---------|-------------|
| `/eggs` or `/eggs help` | Show command reference |
| `/eggs browser` | Open the NM browser to pick which NMs to track |
| `/eggs settings` | Open the settings window |
| `/eggs import` | Run the LSB data import |
| `/eggs <NM Name>` | Open the PH detail window for a specific NM (case-insensitive) |
| `/eggs fav <NM Name>` | Add or remove an NM from favorites |
| `/eggs show` / `/eggs hide` | Show or hide the tracker window |
| `/eggs clear` | Clear all saved timer data |
| `/eggs debug` | Toggle debug mode (shows entity info on PH kill/target) |

**Examples:**
```
/eggs Leaping Lizzy
/eggs valkurm emperor
/eggs Lord of Onzozo
```

---

## UI Overview

### Tracker Window
Shows all tracked NMs. Columns:

| Column | Description |
|--------|-------------|
| NM Name | Click to open PH Detail for that NM |
| Type | `T.Lotto` (Timed Lottery), `Lottery` (True Lottery), `Timed` (Timed Spawn) |
| Status | `Monitoring` / `PH Dead` / `PH Spawned` / `Cooldown` / `Eligible` / `Expired` |
| Timer | Countdown to window open, or countdown to PH respawn |
| Alarm | Toggle per-NM alarm |
| X | Remove from tracking |

### PH Detail Window
Opened via `/eggs <NM Name>` or by clicking an NM name in the Tracker. Shows each placeholder with:
- Live alive/dead status
- Respawn countdown if dead
- Spawn chance %
- Arrow `►` next to whichever PH you are currently targeting

### PH Popup Window
Automatically appears when you target a placeholder mob. Shows the NM name, PH mob name, NM type, and spawn chance. Includes buttons to quickly track the NM or open its PH Detail window.

---

## Settings

Access via `/eggs settings` or the Settings button in the Tracker.

- **Alarm Sound** — Choose from Chime, Bell, Alert Beep, or Soft Ping (with Test button)
- **Volume** — Adjust alarm volume
- **Alarm Triggers** — Toggle alarm on NM window opening and/or PH respawning
- **Early Warning** — Seconds before the event to trigger the alarm (0 = exact moment)
- **Display Options** — Show short IDs (last 3 digits only), adjust UI scale
- **Data** — Run import or clear all timers

---

## How Timers Work

### Lottery NMs (Timed & True)
- When a **PH dies**, a respawn timer starts (typically 5 minutes)
- Each time the PH respawns, the server rolls for the NM to spawn based on spawn chance %
- **Timed Lottery** — after the NM itself dies, a cooldown period must pass before it can pop again
- **True Lottery** — no cooldown; the NM can pop on the very next PH cycle after dying

### Timed Spawn NMs
- No placeholder. After the NM dies, it respawns after a random time within a known window
- The tracker shows `Cooldown` while waiting and `Eligible` when the spawn window opens

### Cross-Session Persistence
Timers are saved with real-world (OS) timestamps. When you reload the addon or log back in, Eggs calculates elapsed time and adjusts all timers automatically. If a window opened or closed while you were offline, it will reflect the correct state immediately on load.

---

## File Structure

```
Ashita/addons/eggs/
├── eggs.lua          Main addon file and command handler
├── gui.lua           All ImGui UI windows
├── tracker.lua       Timer state management and entity tracking
├── nm_data.lua       Zone data loader
├── import.lua        LSB script parser and data generator
├── sounds.lua        Sound playback
├── sounds/
│   ├── chime.wav
│   ├── bell.wav
│   ├── alert.wav
│   └── ping.wav
└── data/             Generated by /eggs import
    ├── 103.lua       (zone files by ID, e.g. South Gustaberg)
    ├── 104.lua
    └── ...
```

---

## Credits

Developed with reference to the following open source Ashita addons:

- **[mobdb](https://github.com/ThornyFFXI/mobdb)** by ThornyFFXI — MIT License  
  Referenced for Ashita v4 memory manager API usage (`GetServerId`, `GetSpawnFlags`, `GetStatus`, zone change packet handling)

- **[PlayerNotes](https://github.com/SQLCommit/PlayerNotes)** by SQLCommit — MIT License  
  Referenced for Ashita sound API usage (`ashita.misc.play_sound`)

---

## License

MIT License

Copyright (c) 2026 MNT

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
