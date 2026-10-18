# Eggs — NM Placeholder Tracker for Ashita v4

**Author:** Monti  
**Version:** 1.0  
**License:** MIT  

An Ashita v4 addon for tracking Notorious Monster placeholders and respawn timers in Final Fantasy XI. Eggs monitors placeholder mob deaths, tracks respawn countdowns, and alerts you when an NM window opens or a PH is due to respawn.

---

## Features

- **PH Detection** — Automatically detects when you target a placeholder mob and shows a popup with the NM name, type, and spawn chance
- **Four UI Windows:**
  1. **Tracker** — All your tracked NMs with live countdown timers and window status
  2. **PH Detail** — Per-NM placeholder list showing which PHs are dead/alive with respawn timers
  3. **PH Popup** — Auto-appears when targeting any placeholder mob (even untracked NMs)
  4. **Loot** — Displays the loot table and drop chance of any NM.
  
- **NM Browser** — Zone-grouped checklist with search to pick which NMs to track
- **Three NM Types Supported:**
  - `Timed Lottery` — Spawns off PH death with a % chance; has a cooldown after its own death
  - `True Lottery` — Same as Timed Lottery but no cooldown; can pop immediately after dying
  - `Timed Spawn` — No placeholder; respawns after a set time window after death
- **Alarm System** — Configurable `.wav` alarms with multiple sounds and early-warning timer (like an egg timer, wow)
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

Eggs reads NM, placeholder and loot data from the Phoenix Repo. The data files in `addons/eggs/data/` are produced by `tools/generate.py`, which replaced the old in-game importer when Phoenix moved mob data out of SQL and `phList` Lua into per-zone YAML.

Requires Python 3 and PyYAML (`python -m pip install pyyaml`).

1. From a terminal, run the generator against your Phoenix checkout:
   ```
   python addons/eggs/tools/generate.py --repo Drive:\YourPhoenixInstall
   ```
   It takes about 20 seconds. Add `--zone <id>` to rebuild a single zone.
2. In game, reload the addon:
   ```
   /addon reload eggs
   ```
   (`/eggs import` just prints these two steps.)

What it reads:

| Source | Used for |
|--------|----------|
| `data/zones/<zone>/mobs.yaml` `slots:` | Lottery NMs: chance, cooldown and the placeholders sharing the NM's spawn slot |
| `modules/**/zones/<zone>/mobs.yaml` | Overlays merged in `modules/init.txt` order (dicts merge, lists replace), e.g. `nm_respawn` cooldown restores and the era dungeon respawn timers |
| `scripts/zones/<Zone>/mobs/*.lua` | Timed-spawn windows (`setRespawnTime`) and the NMs that still use `entity.phList` / `xi.mob.phOnDespawn` (chained or many-placeholder NMs) |
| templates' `loot:` | Drop tables |
| `attributes.spawn.respawn` | Per-spawn respawn for the ID Respawn window (`__resp`) |

If a zone has no `mobs.yaml` (cities, instances) it is skipped; the list is written to `errors.txt`. Files for zones that are no longer generated are removed on a full run.

#### Server modules that change NM timers
The NM scripts alone are not what the server runs. `modules/era/lua/globals/old_nm_respawn_timers.lua` overrides them at runtime to restore the pre-November-2013 timers, and the generator mirrors that table (`ERA_TIMED_NMS`, `ERA_LOTTERY_COOLDOWNS` in `generate.py`): Roc, Morbolger, Juggler Hecatomb, Capricious Cassie, Simurgh and Dosetsu Tree 21-24h, Argus / Leech King 18-30h, Manipulator and Atkorkamuy 2h, Bloodsucker 72h, Lumbering Lambert and Rampaging Ram a 60 minute cooldown. That module only runs when content restriction is on and SOA is off (`xi.pre`), which the repo defaults do not set, so pass `--no-era-timers` if your server is not an era server (and `--no-wotg` if WotG is off). If that module changes, update the tables.

Other things the generator applies on purpose:
- `phoenix/data/nm_respawn` slot overlays (the old lottery cooldowns) and `phoenix/data/drops` loot overlays come through the normal overlay merge.
- Timed windows under 4 minutes are ignored. Those are popped / instanced mobs (Tenzen, the Primes, Dynamis Lord) that call `setRespawnTime` with a few seconds.
- A single fixed timer is written with no close time, so the NM stays "open" after its window starts.
- `pxi_timed_nm_respawn_persistence` only saves and restores windows across restarts, and `era_hnm_system` is disabled, so neither changes the numbers.

---

## Commands

| Command | Description |
|---------|-------------|
| `/eggs` or `/eggs help` | Show command reference |
| `/eggs show` or `/eggs hide` | Show/hide tracker window|
| `/eggs browser` | Open the NM browser to pick which NMs to track |
| `/eggs settings` | Open the settings window |
| `/eggs import` | Show how to regenerate the data (`tools/generate.py`) |
| `/eggs clear <NM Name>` | Clears the timer data for a specified NM |
| `/eggs clear all` | Clears all timer data for tracked NMs |
| `/eggs <NM Name> deathtime` | Show stored ToD for a tracked NM |
| `/eggs track <NM Name>` | Start tracking specified NM |
| `/eggs loot <NM Name>` | Open the loot window to view of any NM |
| `/eggs <NM Name>` | Open the PH detail window for a specific NM (case-insensitive) |
| `/eggs fav <NM Name>` | Add or remove an NM from favorites |
| `/eggs show` / `/eggs hide` | Show or hide the tracker window |
| `/eggs debug` | Toggle debug mode (shows entity info on PH kill/target) |
| `/eggs notify` | Set chat to before in advance before an NM is eligible |
| `/eggs tod <NM Name> HH:MM:SS` | Record an NM death at the specified time today |
| `/eggs tod <NM Name> HH:MM:SS MM/DD/YYYY` |  Record an NM death at the specified date and time |
| `/eggs open <NM Name>` | Gives the time/date for specified NM's window |




**Examples:**
```
/eggs Leaping Lizzy
/eggs tod Cerberus 
/eggs loot Kirin

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
- **Alarm Triggers** — Toggle alarm on NM window opening and/or PH respawning
- **Early Warning** — Seconds before the event to trigger the alarm (0 = exact moment)
- **Display Options** — Show short IDs (last 3 digits only), adjust UI scale
- **Print window open** — Prints the exact real world time a PH/NM will respawn upon death
- **Default Warn** — Receive a notification in chat warning you an NM will be eligible soon
- **Data** — How to import (regenerate data) or clear all timers

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

### Respawn Wave Prediction (all timers)
The server does not spawn a mob the moment its timer ends. Each zone runs a spawn *wave* every 30 seconds and spawns any mob whose respawn time falls within the next 15 seconds. The wave grid is fixed while the map server is up, but its phase is random per zone and is re-rolled on every server restart.

Eggs learns each zone's wave by timing mobs that spawn in front of you (alive, within 30 yalms of you). Mobs respawn anywhere in their spawn region, so it does not matter where they died. Appearances during the 10 seconds after zoning or teleporting, farther than 30 yalms away (draw-distance pop-in), or from scripted respawns are ignored. Then it predicts repops:

```
respawn_at = despawn_start + respawn_secs
repop      = first wave tick (phase + 30k) at or after respawn_at - 15s
```

- Every respawn timer follows the wave once the zone's wave is known, and counts down to the wave tick the mob should pop on instead of the raw timer: the ID Respawn window's **Timer** column, the PH Detail **Respawn** column, PH timers everywhere else, and the alarms and "respawn window is up" message that come from them. A locked wave is green (`~00:09`, about +/-1s). A saved phase that has not been confirmed yet is dim with a `?` (`~00:09?`).
- NM windows follow the wave too, but only for NMs that respawn on their own timer (`timed_spawn`): the window opens and closes on wave ticks. Lottery NMs (`timed_lottery`, `true_lottery`) keep a plain cooldown, because the lottery and its cooldown are checked when the placeholder dies, not on a tick. Their placeholder timers follow the wave.
- When the zone's wave is not known yet (or the clock is still calibrating, or `/eggs wave off`), every timer is the plain timer: death time plus the `despawn_offset` setting plus the respawn timer. Scripted mobs are always exact.
- The ID Respawn window header shows the wave status.
- The wave locks after 3 consistent respawns at least 5 seconds apart in a zone (mobs spawning on the same tick count once). Any mob you see spawn counts, not just the ones you track with `/e`, and you do not need to have seen it die.
- Watching a mob's body vanish gives an exact despawn time (the server starts the respawn clock 3s before the body disappears), for ID-tracked mobs and placeholders. Otherwise Eggs uses the `despawn_offset` setting. The server's real corpse time is 15s, so a value near 15 lines the wave up best.
- A server restart is detected automatically (three tight respawns on a new phase) and the zone relearns.
- Mobs with night, weather or fog conditions, or scripted spawn checks, can skip a wave and appear 30s later. Placeholder/NM identity is decided by the server and is not predicted.
- `/eggs wave <0-59>` sets the current zone's wave by hand: the number is the second past the minute on your PC clock, so `/eggs wave 15` means ticks at :15 and :45. Real spawns still apply afterwards: if they disagree, three of them replace what you set.
- `/eggs wave reset` forgets the current zone (and its saved copy), `/eggs wave reset all` forgets every zone, `/eggs wave off|on` disables or enables prediction, and `/eggs wave debug` prints a diagnostic report. The status is always in the ID Respawn window header.

#### Saved waves
The wave grid only changes when the map server restarts, so a learned phase is still correct on a later day. Eggs saves each zone's phase to `config/addons/Eggs/wave_phases.lua` (shared by every client on this Ashita install) and reuses it:

- A saved phase is shown as an **unconfirmed** prediction (grey `~1:12 (saved)`). Two nearby spawns that agree with it confirm it and it turns green. Three spawns that contradict it mean the server restarted, so it is dropped and relearned.
- Ashita's clock restarts every boot, so phases are stored against real (wall-clock) time. Eggs calibrates the two against each other from `os.time()` ticks; `/eggs wave debug` shows whether that is done.
- The server's timer slowly drifts against real time, so the allowed mismatch grows about 1s per day of age, and a phase older than 3 days is ignored.
- If you restart your own server, run `/eggs wave reset all` to skip the wait for the check to notice.
- Saving is on by default. To turn it off, set `wave_save = false` in the settings file. Learning and prediction inside a session are not affected.

### Respawn Times From Server Data (modules)
For `/e` tracking, Eggs reads each mob's respawn straight from the server's own YAML, the same way the server merges it: `data/zones/<zone>/mobs.yaml`, then every data module enabled in `modules/init.txt` (for example `phoenix/data/launch_starter_zones`), in order. A spawn-level respawn beats the template's. The per-spawn respawn that `tools/generate.py` writes into `data/` is only used when the YAML does not say.

- The launch starter zone module's extra mobs (offsets 824-1023 in the six starter zones) are respawned by script 15s after death, not by the wave. Eggs marks them `scripted`, starts their clock at death, and keeps them out of wave learning.
- NM placeholder timers also use a module's respawn when a module sets one for that exact spawn.
- The files are re-read about once a minute, so edits to the yaml show up on their own. The server folder is `C:\Phoenix-Workspace`; change `lsb_server_path` in the settings file if yours differs.

---

## File Structure

```
Ashita/addons/eggs/
├── eggs.lua          Main addon file and command handler
├── gui.lua           All ImGui UI windows
├── tracker.lua       Timer state management and entity tracking
├── wave.lua          Respawn wave learning and repop prediction
├── yaml_respawn.lua  Respawn times from server yaml and modules
├── nm_data.lua       Zone data loader
├── import.lua        Prints how to regenerate data (importer retired)
├── tools/generate.py  Builds data/ from the Phoenix workspace YAML + scripts
├── sounds.lua        Sound playback
├── sounds/
│   ├── chime.wav
│   ├── bell.wav
│   ├── alert.wav
│   └── ...
└── data/             Generated by tools/generate.py
    ├── 103.lua       (zone files by ID, e.g. South Gustaberg)
    ├── 104.lua
    └── ...
```

---

## Credits

Developed with reference to the following open source Ashita addons:

- **[mobdb](https://github.com/ThornyFFXI/mobdb)** by ThornyFFXI — MIT License  
  Referenced for Ashita v4 memory manager API usage (`GetServerId`, `GetSpawnFlags`, `GetStatus`, zone change packet handling)

---

## License

MIT License

Copyright (c) 2026 Montijin

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
