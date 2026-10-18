------------------------------------------------------------
-- tracker.lua
-- Manages all active PH and NM timer state.
--
-- Timer keys:
--   PH timers:  "ph:<mob_id>"
--   NM timers:  "nm:<nm_name_sanitized>"
--
-- Each timer entry contains:
--   type         = 'ph' | 'nm'
--   nm_name      = string    NM this timer belongs to
--   ph_name      = string    PH mob name (PH timers only)
--   ph_mob_id    = number    PH server mob ID (PH timers only)
--   zone_id      = number    Zone where the death occurred
--   respawn_secs = number    PH: respawn time; NM: window open time (seconds)
--   window_secs  = number    NM: window close time (0 = no known close)
--   tod_os       = number    os.time() when death was recorded
--   alarm_fired  = bool      Whether the alarm has already played this cycle
------------------------------------------------------------

require('common');
local chat = require('chat');
local wave = require('wave');

local tracker = {};

-- Respawn wave learning (see wave.lua). Exposed so the GUI/commands can use it.
tracker.Wave = wave;

tracker.WaveZone  = 0;

local WAVE_NEAR_YALMS  = 30;    -- a spawn must appear within this of the player
local WAVE_DESPAWN_FADE = 3;    -- server removes the body 3s after despawn starts

-- Diagnostics for /eggs wave debug: counters, a short event log, and poll info.
tracker.WaveStats  = {};
tracker.WaveLog    = {};
tracker.PollCount  = 0;
tracker.LastPollHr = 0;

local function wcount(key)
    tracker.WaveStats[key] = (tracker.WaveStats[key] or 0) + 1;
end

-- Count an event and keep a line of it in the log. Also prints live when
-- gSettings.wave_debug is on (/eggs wave debug on).
local function wnote(key, msg)
    wcount(key);
    tracker.WaveLog[#tracker.WaveLog + 1] = os.date('%H:%M:%S') .. '  ' .. msg;
    if #tracker.WaveLog > 40 then table.remove(tracker.WaveLog, 1); end
    if gSettings and gSettings.wave_debug then
        print(chat.header('Eggs') .. chat.message('[wave] ' .. msg));
    end
end

-- Active timers in memory. Mirrors gSettings.tod_data but as live objects.
tracker.ActiveTimers = T{};

-- Generic mob respawn timers for the "ID Respawn Tracking" window.
-- Keyed by tostring(mob_id). Mirrors gSettings.id_tracked.
-- Plain table (not T{}) so membership tests on unknown keys are false.
-- Entry fields:
--   mob_id, sp_index, name, zone_id
--   respawn_secs  = seconds from death to respawn
--   is_estimate   = true when respawn_secs is the configured default (no data)
--   state         = 'alive' | 'dead'
--   tod_os        = os.time() of death (nil while alive)
--   alarm_fired   = early-warning alarm already played this cycle
--   due_notified  = "window is up" chat line already printed this cycle
tracker.IdTargets = {};

-- Populated each poll: [sp_index] = entity status for mobs present right now.
tracker.PresentIndex = {};
tracker.CurrentZone  = 0;

-- Last seen entity state per entity slot, used for death detection.
-- [entity_index] = { s=status, id=mob_id, n=name, sp=sp_index, c=poll_count }
tracker.LastStatus = {};

-- FFXI entity status values we consider "dead".
-- Status 3 confirmed as dead on LSB private server (e.g. Flying Manta: 1->3 on death).
local DEAD_STATUSES = { [3] = true };

-- Real wall-clock now with sub-second precision, or nil until the wave module
-- has calibrated Ashita's clock against os.time().
local function wall_now()
    local off = wave.WallOffset();
    return off and (wave.Now() + off) or nil;
end

-- Grace period in seconds after a PH respawn before auto-clearing its timer.
-- This gives the player time to see the "PH Spawned" status before it disappears.
local PH_GRACE_SECS = 120;

------------------------------------------------------------
-- Initialize
-- Restores timers from saved settings on addon load.
-- Drops any timers that already fully expired while offline.
------------------------------------------------------------
tracker.Initialize = function(self)
    self.ActiveTimers = T{};

    -- Restore generic ID respawn timers. If a mob was dead and its respawn
    -- already elapsed while offline, assume it is back up.
    self.IdTargets = {};
    if gSettings.id_tracked then
        local now = os.time();
        for key, s in pairs(gSettings.id_tracked) do
            local e = {
                mob_id       = s.mob_id,
                sp_index     = s.sp_index or ((s.mob_id or 0) % 1024),
                name         = s.name or '?',
                zone_id      = s.zone_id or 0,
                respawn_secs = s.respawn_secs or 300,
                scripted     = s.scripted or false,
                manual       = s.manual or false,
                is_estimate  = s.is_estimate or false,
                state        = s.state or 'alive',
                tod_os       = s.tod_os,
                tod_wall     = s.tod_wall,
                tod_exact    = s.tod_exact or false,
                alarm_fired  = s.alarm_fired or false,
                due_notified = s.due_notified or false,
                note         = s.note or '',
            };
            if e.state == 'dead' and e.tod_os
               and (now - e.tod_os) >= e.respawn_secs then
                e.state = 'alive';
                e.tod_os = nil;
                e.tod_wall = nil;
                e.alarm_fired = false;
                e.due_notified = false;
            end
            self.IdTargets[key] = e;
        end
    end

    if not gSettings.tod_data then return; end

    local now     = os.time();
    local expired = {};

    for key, saved in pairs(gSettings.tod_data) do
        local elapsed = now - (saved.tod_os or 0);
        local is_ph_expired = saved.type == 'ph' and elapsed >= (saved.respawn_secs or 0);
        local is_nm_expired = saved.type == 'nm'
            and (saved.window_secs or 0) > 0
            and elapsed >= (saved.window_secs or 0);

        if is_ph_expired or is_nm_expired then
            expired[#expired + 1] = key;
        else
            self.ActiveTimers[key] = {
                type         = saved.type,
                nm_name      = saved.nm_name,
                ph_name      = saved.ph_name,
                ph_mob_id    = saved.ph_mob_id,
                zone_id      = saved.zone_id,
                respawn_secs = saved.respawn_secs,
                window_secs  = saved.window_secs or 0,
                tod_os       = saved.tod_os,
                tod_wall     = saved.tod_wall,
                on_wave      = saved.on_wave,
                alarm_fired  = saved.alarm_fired or false,
                notify_secs  = saved.notify_secs or nil,
                notify_fired = saved.notify_fired or false,
            };
        end
    end

    -- Remove expired entries from persistent storage
    for _, key in ipairs(expired) do
        gSettings.tod_data[key] = nil;
    end
    if #expired > 0 then gSaveSettings(); end
end;

------------------------------------------------------------
-- RecordDeath
-- Starts a new timer for a PH or NM death.
-- tod_os_override: use this timestamp instead of now (for /eggs tod manual entry).
------------------------------------------------------------
tracker.RecordDeath = function(self, dtype, nm_name, ph_name, ph_mob_id, zone_id, respawn_secs, window_secs, tod_os_override)
    -- Build the storage key
    local key;
    if dtype == 'ph' then
        key = string.format('ph:%d', ph_mob_id or 0);
    else
        key = string.format('nm:%s', nm_name:gsub('[^%w]', '_'));
    end

    -- The server starts the respawn clock when the body despawns, not at HP=0.
    -- We add a configurable offset to compensate. Manual /eggs tod entries
    -- bypass this since the player is providing an already-adjusted timestamp.
    local offset = (tod_os_override == nil) and (gSettings.despawn_offset or 10) or 0;
    local tod    = tod_os_override or (os.time() + offset);

    -- Sub-second version of the same moment, so wave timing is not rounded to
    -- whole seconds. Only for live deaths; a typed-in ToD has no such precision.
    local now_wall = (tod_os_override == nil) and wall_now() or nil;
    local tod_wall = now_wall and (now_wall + offset) or nil;

    -- Preserve any manually-set notify from the previous timer for this NM,
    -- so a /eggs notify set before /eggs tod isn't silently lost.
    local prev_notify = nil;
    if dtype == 'nm' then
        for _, existing in pairs(self.ActiveTimers) do
            if existing.type == 'nm' and existing.nm_name == nm_name
            and existing.notify_secs and not existing.notify_fired then
                prev_notify = existing.notify_secs;
                break;
            end
        end
    end

    local entry = {
        type         = dtype,
        nm_name      = nm_name,
        ph_name      = ph_name,
        ph_mob_id    = ph_mob_id,
        zone_id      = zone_id,
        respawn_secs = respawn_secs,
        window_secs  = window_secs or 0,
        tod_os       = tod,
        tod_wall     = tod_wall,
        alarm_fired  = false,
        notify_secs  = prev_notify or ((dtype == 'nm' and gSettings.notify_default)
                       and ((gSettings.notify_default_mins or 60) * 60) or nil),
        notify_fired = false,
    };

    self.ActiveTimers[key] = entry;

    -- When a PH dies, clear its confirmed-alive state so the UI shows
    -- it as unconfirmed until the player targets it again after respawn.
    if dtype == 'ph' and ph_mob_id and ph_mob_id > 0 then
        if not gSettings.ph_confirmed then gSettings.ph_confirmed = {}; end
        gSettings.ph_confirmed[ph_mob_id] = nil;
    end

    -- Persist to disk
    gSettings.tod_data[key] = entry;
    gSaveSettings();

    -- Print confirmation
    local label   = dtype == 'ph' and (ph_name or 'PH') or nm_name;
    local tod_str = os.date('%m/%d/%Y %H:%M:%S', tod);
    print(chat.header('Eggs') .. chat.message(
        string.format('[%s] died at %s. Timer started (%ds respawn).', label, tod_str, respawn_secs)));

    -- Optionally print the real-world clock time when the window opens.
    -- tod already has the despawn offset baked in, so tod + respawn_secs
    -- gives the correct offset-adjusted eligible time.
    -- Omits day of week if the window opens today.
    if gSettings.print_window_time and respawn_secs > 0 then
        local open_time = tod + respawn_secs;
        local today     = os.date('%Y%m%d', os.time());
        local function fmt_clock(t)
            if os.date('%Y%m%d', t) == today then return os.date('%I:%M:%S %p', t); end
            return os.date('%a %I:%M:%S %p', t);
        end
        if (window_secs or 0) > 0 then
            local close_time = tod + window_secs;
            print(chat.header('Eggs') .. chat.message(string.format(
                '[%s] Eligible: %s - %s', nm_name, fmt_clock(open_time), fmt_clock(close_time))));
        else
            print(chat.header('Eggs') .. chat.message(string.format(
                '[%s] Eligible at: %s', nm_name, fmt_clock(open_time))));
        end
    end
end;

------------------------------------------------------------
-- RemoveTimer
-- Removes a timer from both memory and persistent storage.
------------------------------------------------------------
tracker.RemoveTimer = function(self, key)
    self.ActiveTimers[key] = nil;
    gSettings.tod_data[key] = nil;
    gSaveSettings();
end;

------------------------------------------------------------
-- Respawn timers and the wave
-- The server does not spawn a mob the moment its timer ends: a wave tick
-- every 30s spawns whatever is due within the next 15s (see wave.lua). So the
-- real repop is the first tick at or after  despawn + respawn - 15s.
--
-- Every timer in the addon goes through RepopRemaining:
--   wave known ('locked' / 'saved')  -> seconds until that tick
--   wave unknown ('plain')           -> the plain timer, which already
--                                       includes the despawn_offset setting
------------------------------------------------------------

-- Seconds until a mob despawned at `despawn_os` (os.time scale, offset
-- already applied) with `respawn_secs` should be back; negative once due.
-- `despawn_wall` is a sub-second version of the same moment when we have one.
-- Returns remaining, kind ('locked' | 'saved' | 'plain').
tracker.RepopRemaining = function(self, zone_id, despawn_os, respawn_secs, despawn_wall)
    local plain = respawn_secs - (os.time() - despawn_os);

    if gSettings.wave_enabled == false or not zone_id or zone_id == 0 then
        return plain, 'plain';
    end

    local now_wall = wall_now();
    if not now_wall then return plain, 'plain'; end

    local at, kind = wave:RepopWall(zone_id, despawn_wall or despawn_os, respawn_secs);
    if not at then return plain, 'plain'; end
    return at - now_wall, kind;
end;

-- A generic ID-tracked mob. Scripted respawns (launch module extras) do not
-- use the wave.
tracker.IdRemaining = function(self, e)
    if e.scripted then
        return e.respawn_secs - (os.time() - e.tod_os), 'plain';
    end
    return self:RepopRemaining(e.zone_id, e.tod_os, e.respawn_secs, e.tod_wall);
end;

------------------------------------------------------------
-- GetRemaining
-- Returns seconds until a PH respawns (negative if already past), and
-- whether that came from the wave ('locked'/'saved') or the plain timer.
------------------------------------------------------------
tracker.GetRemaining = function(self, entry)
    return self:RepopRemaining(entry.zone_id, entry.tod_os, entry.respawn_secs, entry.tod_wall);
end;

------------------------------------------------------------
-- ID Respawn Tracking helpers
------------------------------------------------------------

-- Mirror one IdTargets entry to persistent storage (nil key => delete).
tracker.SaveIdTarget = function(self, key)
    if not gSettings.id_tracked then gSettings.id_tracked = {}; end
    local e = self.IdTargets[key];
    if not e then
        gSettings.id_tracked[key] = nil;
    else
        gSettings.id_tracked[key] = {
            mob_id       = e.mob_id,
            sp_index     = e.sp_index,
            name         = e.name,
            zone_id      = e.zone_id,
            respawn_secs = e.respawn_secs,
            scripted     = e.scripted,
            manual       = e.manual,
            is_estimate  = e.is_estimate,
            state        = e.state,
            tod_os       = e.tod_os,
            tod_wall     = e.tod_wall,
            tod_exact    = e.tod_exact,
            alarm_fired  = e.alarm_fired,
            due_notified = e.due_notified,
            note         = e.note,
        };
    end
    gSaveSettings();
end;

-- Start tracking a generic mob. Returns false if already tracked.
tracker.AddIdTarget = function(self, mob_id, sp_index, name, zone_id, respawn_secs, is_estimate, note, scripted, manual)
    local key = tostring(mob_id);
    if self.IdTargets[key] then return false; end
    self.IdTargets[key] = {
        mob_id       = mob_id,
        sp_index     = sp_index,
        name         = name,
        zone_id      = zone_id,
        respawn_secs = respawn_secs,
        scripted     = scripted and true or false,   -- respawned by script, not by the wave
        manual       = manual and true or false,     -- respawn set by the player with /e <secs>; never auto-corrected
        is_estimate  = is_estimate and true or false,
        state        = 'alive',
        tod_os       = nil,
        alarm_fired  = false,
        due_notified = false,
        note         = note or '',
    };
    self:SaveIdTarget(key);
    return true;
end;

tracker.RemoveIdTarget = function(self, key)
    self.IdTargets[key] = nil;
    if gSettings.id_tracked then gSettings.id_tracked[key] = nil; end
    gSaveSettings();
end;

-- Set (or clear, with '') the free-text note on a tracked mob.
-- Returns true if the mob was tracked.
tracker.SetIdNote = function(self, mob_id, note)
    local key = tostring(mob_id);
    local e   = self.IdTargets[key];
    if not e then return false; end
    e.note = note or '';
    self:SaveIdTarget(key);
    return true;
end;

-- Re-read a tracked mob's respawn from the server data, so an entry saved
-- earlier (from the import, or before a module changed it) is
-- corrected. Manual /e <secs> values are never touched.
tracker.RefreshIdRespawn = function(self, key)
    local e = self.IdTargets[key];
    if not e or e.manual then return false; end

    local r, _, scripted = gYamlRespawn.Resolve(e.zone_id, e.mob_id);
    if r == nil then return false; end

    scripted = scripted and true or false;
    if r == e.respawn_secs and scripted == (e.scripted and true or false) and not e.is_estimate then
        return false;
    end

    if r ~= e.respawn_secs then
        print(chat.header('Eggs') .. chat.message(string.format(
            '[%s] respawn corrected %s -> %s (server data).',
            e.name, self:FormatTime(e.respawn_secs), self:FormatTime(r))));
    end
    e.respawn_secs = r;
    e.scripted     = scripted;
    e.is_estimate  = false;
    self:SaveIdTarget(key);
    return true;
end;

-- Record the death of a generic ID-tracked mob (starts its respawn clock).
-- Called from CheckAndRecordDeath; returns true if the mob was tracked.
tracker.RecordIdDeath = function(self, mob_id)
    local key = tostring(mob_id);
    local e   = self.IdTargets[key];
    if not e then return false; end
    if e.state == 'dead' then return true; end

    self:RefreshIdRespawn(key);   -- use the current server data for this cycle

    -- The server starts the respawn clock when the body despawns, not at
    -- HP=0. Push the recorded ToD forward by the same configurable offset
    -- used for NM/PH timers so the countdown lines up with the server.
    local offset = gSettings.despawn_offset or 10;

    -- Scripted respawns (launch module extras) come back a fixed time after
    -- death, not after the despawn, so their clock starts at the death itself.
    if e.scripted then offset = 0; end

    local now_wall = wall_now();

    e.state        = 'dead';
    e.tod_os       = os.time() + offset;
    e.tod_wall     = now_wall and (now_wall + offset) or nil;   -- sub-second copy for wave timing
    e.tod_exact    = e.scripted and true or false;  -- becomes true once we see the body despawn
    e.alarm_fired  = false;
    e.due_notified = false;
    self:SaveIdTarget(key);

    print(chat.header('Eggs') .. chat.message(string.format(
        '[%s] died. Respawn in %s%s.',
        e.name, self:FormatTime(e.respawn_secs),
        e.is_estimate and ' (est)' or '')));
    return true;
end;

------------------------------------------------------------
-- Respawn wave learning
-- The wave grid is a property of the zone, so any mob we see spawn in front
-- of us gives its phase. Nothing about how or where the mob died matters.
------------------------------------------------------------
local function dist2d(ax, az, bx, bz)
    local dx, dz = ax - bx, az - bz;
    return math.sqrt(dx * dx + dz * dz);
end

-- The dead body of a mob just vanished from the entity list. This has
-- nothing to do with learning the wave; it only sharpens the death time of
-- ID-tracked mobs. The server starts the respawn clock when the despawn
-- begins, which is 3s before the body disappears. That is far more exact
-- than a fixed offset from the moment HP hit 0.
tracker.WaveOnBodyCleared = function(self, mob_id, hr)
    local off       = wave.WallOffset();
    local now_os    = os.time();
    local start_os  = math.floor(now_os - WAVE_DESPAWN_FADE);
    local start_wal = off and (hr + off - WAVE_DESPAWN_FADE) or nil;
    local fixed     = false;

    -- A generic ID-tracked mob.
    local key = tostring(mob_id);
    local e   = self.IdTargets[key];
    if e and e.state == 'dead' and not e.scripted then
        e.tod_os    = start_os;
        e.tod_wall  = start_wal;
        e.tod_exact = true;
        self:SaveIdTarget(key);
        fixed = true;
    end

    -- A placeholder timer started by this same death (a few seconds ago).
    local pk = string.format('ph:%d', mob_id);
    local p  = self.ActiveTimers[pk];
    if p and p.type == 'ph' and p.tod_os and (now_os - p.tod_os) < 60 then
        p.tod_os    = start_os;
        p.tod_wall  = start_wal;
        p.tod_exact = true;
        gSaveSettings();
        fixed = true;
    end

    if fixed then
        wnote('cleared', string.format('body of %d cleared, respawn clock started 3s earlier', mob_id));
    else
        wcount('cleared_untracked');
    end
end;

-- A mob newly appeared alive close to us. Any real spawn in view is a wave
-- sample. What has to be ruled out is everything that only looks like one:
--   zone-in / teleport   (whole area loads at once -> settle window)
--   draw-distance pop-in (happens at the edge -> distance limit)
--   scripted respawns    (launch module extras -> not on the wave)
tracker.WaveOnSpawnSeen = function(self, mob_id, hr, zone_id, mx, mz, px, pz)
    if hr < (self.WaveSettleUntil or 0) then wcount('s_settling'); return; end
    if gYamlRespawn.IsScripted(zone_id, mob_id) then wcount('s_scripted'); return; end
    if not (mx and px) then wcount('s_nopos'); return; end

    -- A real spawn in view can be anywhere inside the draw range, but a
    -- pop-in always happens near its edge, so only trust appearances well
    -- inside it.
    local d   = dist2d(px, pz, mx, mz);
    local max = (gSettings and gSettings.wave_appear_max) or WAVE_NEAR_YALMS;
    if d > max then wcount('s_far'); return; end

    local result = wave:AddSample(zone_id, hr);
    wnote('sample', string.format('spawn of %d seen %.0f yalms away: %s (wave phase %.2f)',
        mob_id, d, result, hr % 30));
    if result == 'locked' then
        print(chat.header('Eggs') .. chat.message(
            'Respawn wave locked for this zone. Respawn timers now include the wave.'));
    elseif result == 'confirmed' then
        print(chat.header('Eggs') .. chat.message(
            'Saved respawn wave confirmed for this zone. Respawn timers now include the wave.'));
    elseif result == 'regrid' then
        print(chat.header('Eggs') .. chat.message(
            'Respawn wave changed (server restart?). Relearning this zone.'));
    end

    local z = wave.Zones[zone_id];
    if z and z.saved_rejected then
        z.saved_rejected = nil;
        print(chat.header('Eggs') .. chat.message(
            'Saved wave for this zone did not match (server restarted?). Using the new one.'));
    end
    if z and z.locked and result ~= 'duplicate' and result ~= 'outlier' then
        -- New locks are written at once; later refinements are throttled.
        wave:Persist(zone_id, result == 'locked' or result == 'confirmed' or result == 'regrid');
    end
end;

------------------------------------------------------------
-- GetNMWindowStatus
-- Returns the current state of an NM respawn window.
--   'waiting' = cooldown not yet elapsed
--   'open'    = inside the spawn window
--   'expired' = past the last possible spawn time
-- Also returns seconds until open and seconds until close.
------------------------------------------------------------
tracker.GetNMWindowStatus = function(self, entry)
    local close_at = entry.window_secs;  -- 0 means no known close time

    -- A timed NM comes back through the wave like any other mob, so the window
    -- edges are wave ticks. A lottery NM's cooldown is checked when its
    -- placeholder dies, not on a tick, so it stays a plain timer.
    local zone = tracker.NMOnWave(entry) and entry.zone_id or nil;

    local until_open  = self:RepopRemaining(zone, entry.tod_os, entry.respawn_secs, entry.tod_wall);
    local until_close = nil;
    if close_at > 0 then
        until_close = self:RepopRemaining(zone, entry.tod_os, close_at, entry.tod_wall);
    end

    if until_open > 0 then
        -- Still in cooldown
        return 'waiting', until_open, until_close;
    end

    if until_close and until_close <= 0 then
        -- Past all windows
        return 'expired', 0, 0;
    end

    -- Window is open
    return 'open', 0, until_close;
end;

-- True when an NM timer's window edges are set by the respawn wave: NMs that
-- respawn on their own timer ('timed_spawn'). Cached on the entry.
tracker.NMOnWave = function(entry)
    if entry.on_wave == nil then
        local rec = entry.nm_name and (gNmData:GetNM(entry.nm_name) or gNmData:GetNMAnyZone(entry.nm_name));
        if not rec then return false; end     -- unknown yet: plain, and look again later
        entry.on_wave = (rec.NMType == 'timed_spawn');
    end
    return entry.on_wave;
end;

------------------------------------------------------------
-- PollEntities
-- Called every ~6 frames. Scans the entity list for status
-- changes and fires CheckAndRecordDeath on death transitions.
------------------------------------------------------------
tracker.PollEntities = function(self)
    local em      = AshitaCore:GetMemoryManager():GetEntity();
    local zone_id = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
    local dbg     = gSettings and gSettings.debug_mode;

    -- Rebuilt every poll: which spawn indices are on screen right now, and
    -- their status. Used by Tick() to confirm ID-tracked mobs have respawned.
    local present = {};
    self.CurrentZone = zone_id;

    -- Respawn wave learning: sub-second clock and the player's position.
    local wave_on = gSettings.wave_enabled ~= false;
    local hr, px, pz = 0, nil, nil;
    self.PollCount  = (self.PollCount or 0) + 1;
    self.LastPollHr = wave.Now();
    if wave_on then
        hr = self.LastPollHr;
        local pidx = AshitaCore:GetMemoryManager():GetParty():GetMemberTargetIndex(0);
        if pidx and pidx > 0 then
            px = em:GetLocalPositionX(pidx);
            pz = em:GetLocalPositionZ(pidx);
        end
        -- Pin Ashita's clock to real time so a saved phase means something
        -- in a later session.
        wave:Calibrate(hr, os.time());

        if self.WaveZone ~= zone_id then
            self.WaveZone  = zone_id;
            self.WaveSettleUntil = hr + 10;   -- the whole area is loading in
            wave:LoadFile();                  -- another client may have saved this zone
        end
        -- A teleport or warp inside the zone loads a new area all at once.
        if px and self.WaveLastPx and dist2d(px, pz, self.WaveLastPx, self.WaveLastPz) > 40 then
            self.WaveSettleUntil = hr + 10;
        end
        self.WaveLastPx, self.WaveLastPz = px, pz;
    end

    for idx = 1, 0x7FF do
        local name   = em:GetName(idx);
        local mob_id = em:GetServerId(idx);

        if name and name ~= '' and mob_id and mob_id > 0 then
            -- Entity is present in this slot
            local status   = em:GetStatus(idx);
            local sp_index = mob_id % 1024;
            local last     = self.LastStatus[idx];

            present[sp_index] = status;

            if last == nil then
                -- First poll for this entity — record initial state.
                -- Whether it is a mob is read now, while it is alive, because
                -- the flags of a dead body are not guaranteed to stay the same.
                local is_mob = bit.band(em:GetSpawnFlags(idx), 0x10) ~= 0;
                self.LastStatus[idx] = { s = status, id = mob_id, n = name, sp = sp_index, c = 1, mob = is_mob };

                -- A mob we watched die is present and alive again.
                if wave_on and is_mob and not DEAD_STATUSES[status] then
                    self:WaveOnSpawnSeen(mob_id, hr, zone_id, em:GetLocalPositionX(idx), em:GetLocalPositionZ(idx), px, pz);
                end
            else
                last.c = (last.c or 0) + 1;

                -- Debug: log every status change for PH/NM mobs
                if dbg and last.s ~= status then
                    local is_ph = gNmData:GetNMForPH(sp_index);
                    if is_ph or (gNmData.NMs and gNmData.NMs[name]) then
                        print(chat.header('Eggs') .. chat.message(string.format(
                            'STATUS: idx=%d %s mob_id=%d sp=%d  %d -> %d  (ph=%s)',
                            idx, name, mob_id, sp_index, last.s, status, is_ph or 'NM')));
                    end
                end

                -- Fire death detection on the transition into a dead status
                if DEAD_STATUSES[status] and not DEAD_STATUSES[last.s] then
                    if dbg then
                        print(chat.header('Eggs') .. chat.message(string.format(
                            'Death detected: idx=%d name=%s mob_id=%d sp=%d status=%d->%d',
                            idx, name, mob_id, sp_index, last.s, status)));
                    end
                    self:CheckAndRecordDeath(idx, name, mob_id, sp_index, zone_id);
                    -- Generic ID Respawn Tracking is driven only by a real
                    -- death transition (not the despawn-out-of-range path),
                    -- so a mob wandering off screen never starts its clock.
                    self:RecordIdDeath(mob_id);

                    -- Remember when it died. Wave learning does not need this,
                    -- but a mob cannot really be alive again seconds later, so
                    -- an instant dead->alive flip is a status glitch, not a spawn.
                    wcount('deaths_seen');
                    last.dead_hr = hr;
                end

                -- Dead -> alive without the slot ever going empty: the client
                -- reused the entity in place. Still a real respawn.
                if wave_on and last.mob and DEAD_STATUSES[last.s] and not DEAD_STATUSES[status] then
                    if last.dead_hr and hr - last.dead_hr < 10 then
                        wcount('appear_early');
                    else
                        wcount('appear_in_place');
                        self:WaveOnSpawnSeen(mob_id, hr, zone_id, em:GetLocalPositionX(idx),
                            em:GetLocalPositionZ(idx), px, pz);
                    end
                end

                last.s  = status;
                last.id = mob_id;
            end
        else
            -- Slot is empty — entity has despawned or we changed zones
            local last = self.LastStatus[idx];
            if last and last.id and last.id > 0 then
                if DEAD_STATUSES[last.s] then
                    -- Body of a dead mob cleared — timer already running.
                    -- The despawn started 3s ago, which is when the server's
                    -- respawn clock actually began.
                    if wave_on then self:WaveOnBodyCleared(last.id, hr); end
                    if dbg then
                        local is_ph = gNmData:GetNMForPH(last.sp or 0);
                        if is_ph then
                            print(chat.header('Eggs') .. chat.message(string.format(
                                'BodySlotCleared: idx=%d name=%s (timer already running)',
                                idx, last.n or '?')));
                        end
                    end
                elseif (last.c or 0) >= 3 then
                    -- Alive entity disappeared without dying (e.g. de-popped NM or despawn)
                    -- Must have seen it for at least 3 polls to rule out zone flicker
                    if dbg then
                        print(chat.header('Eggs') .. chat.message(string.format(
                            'Despawn(no death): idx=%d name=%s mob_id=%d sp=%d polls=%d',
                            idx, last.n or '?', last.id, last.sp or 0, last.c or 0)));
                    end
                    self:CheckAndRecordDeath(idx, last.n or '', last.id, last.sp or 0, zone_id);
                end
            end
            self.LastStatus[idx] = nil;
        end
    end

    self.PresentIndex = present;
end;

------------------------------------------------------------
-- CheckAndRecordDeath
-- Determines whether a dying entity is a tracked PH or NM
-- and starts the appropriate timer.
------------------------------------------------------------
tracker.CheckAndRecordDeath = function(self, entity_index, entity_name, mob_id, sp_index, zone_id, from_despawn)
    local dbg     = gSettings and gSettings.debug_mode;
    local nm_name = gNmData:GetNMForPH(sp_index);

    if dbg then
        print(chat.header('Eggs') .. chat.message(string.format(
            'CheckDeath: name=%s sp_idx=%d ph_match=%s despawn=%s',
            entity_name, sp_index, nm_name or 'none', tostring(from_despawn or false))));
    end

    -- Body-despawn path: update an existing PH timer's start time to now.
    -- The server starts the respawn clock at body despawn, not at HP=0.
    if from_despawn then
        if not nm_name then return; end
        local ph_key = string.format('ph:%d', mob_id);
        if not self.ActiveTimers[ph_key] then return; end
        local now = os.time();
        self.ActiveTimers[ph_key].tod_os = now;
        if gSettings.tod_data and gSettings.tod_data[ph_key] then
            gSettings.tod_data[ph_key].tod_os = now;
            gSaveSettings();
        end
        if dbg then
            print(chat.header('Eggs') .. chat.message('Body despawned - timer reset to now for ' .. nm_name));
        end
        return;
    end

    -- PH death path: entity is a placeholder for a known NM
    if nm_name then
        -- Always show the PH popup (even if not tracking the NM)
        pcall(function() gGui:ShowPHPopup(nm_name, entity_name, mob_id); end);

        local is_tracked = gSettings.tracked and gSettings.tracked[nm_name];
        if dbg then
            print(chat.header('Eggs') .. chat.message(string.format(
                'NM=%s tracked=%s', nm_name, tostring(is_tracked ~= nil))));
        end

        if not is_tracked then return; end

        -- Find the NM entry (try current zone first, then cross-zone)
        local nm_entry = gNmData:GetNM(nm_name) or gNmData:GetNMAnyZone(nm_name);
        if dbg then
            print(chat.header('Eggs') .. chat.message(
                'nm_entry=' .. (nm_entry and 'found' or 'NIL - not in current zone!')));
        end
        if not nm_entry then return; end

        -- Find the respawn time for this specific PH
        local ph_respawn = 300;  -- default 5 minutes if not found in data
        if nm_entry.PHs then
            for _, ph in ipairs(nm_entry.PHs) do
                if ph.Index == sp_index then
                    local rt = ph.RespawnTime or 0;
                    ph_respawn = (rt > 0) and rt or 300;
                    if dbg then
                        print(chat.header('Eggs') .. chat.message(string.format(
                            'PH match: Index=%d RespawnTime=%d', ph.Index, ph_respawn)));
                    end
                    break;
                end
            end
        end

        -- A data module (e.g. launch starter zones) can set the real respawn
        -- for this exact spawn. That beats the imported value, which can be
        -- stale or pre-module. Core-only values are left to the import data,
        -- since NM scripts can override those at runtime.
        local yr, _, yscripted, y_from_module = gYamlRespawn.Resolve(zone_id, mob_id);
        if yr and yr > 0 and y_from_module and not yscripted then
            ph_respawn = yr;
        end

        if dbg then
            print(chat.header('Eggs') .. chat.message(string.format(
                'Calling RecordDeath: ph=%s nm=%s respawn=%d', entity_name, nm_name, ph_respawn)));
        end
        self:RecordDeath('ph', nm_name, entity_name, mob_id, zone_id, ph_respawn, 0);
        return;
    end

    -- NM death path: entity is the NM itself
    local nm_entry = gNmData:GetNM(entity_name) or gNmData:GetNMAnyZone(entity_name);
    if not nm_entry then return; end
    if not (gSettings.tracked and gSettings.tracked[entity_name]) then return; end

    -- If the NM data has a specific mob_id (e.g. Bloodsucker NM shares its name with
    -- regular mobs), verify we have the right one before recording the death.
    if nm_entry.NMMobId and nm_entry.NMMobId > 0 and mob_id ~= nm_entry.NMMobId then return; end

    local tracked_name = entity_name;

    -- Clear confirmed-alive state since the NM just died
    if gGui and gGui.NMConfirmedUp then
        gGui.NMConfirmedUp[tracked_name] = nil;
    end

    -- Determine the respawn window bounds
    local window_min, window_max;
    if nm_entry.NMType == 'timed_spawn' then
        window_min = nm_entry.WindowMin or 3600;
        window_max = nm_entry.WindowMax or 0;
    else
        window_min = nm_entry.Cooldown or 0;
        window_max = 0;
    end

    if dbg then
        print(chat.header('Eggs') .. chat.message(string.format(
            'NM death: %s (tracked as "%s") type=%s window=%d-%d',
            entity_name, tracked_name, nm_entry.NMType or '?', window_min, window_max)));
    end

    if window_min == 0 and window_max == 0 then
        -- True lottery NM: no cooldown, PHs resume immediately
        print(chat.header('Eggs') .. chat.message(
            '[' .. tracked_name .. '] died. PHs resume immediately (no cooldown).'));
    else
        self:RecordDeath('nm', tracked_name, nil, 0, zone_id, window_min, window_max);
    end

    -- Remove any stale PH timers for this NM now that it has died
    local to_del = {};
    for key, entry in pairs(self.ActiveTimers) do
        if entry.nm_name == tracked_name and entry.type == 'ph' then
            to_del[#to_del + 1] = key;
        end
    end
    for _, k in ipairs(to_del) do self:RemoveTimer(k); end
end;

------------------------------------------------------------
-- Tick
-- Called every frame from gui:Render().
-- Fires alarms and cleans up expired PH timers.
------------------------------------------------------------
tracker.Tick = function(self)
    local warn      = gSettings.alarm_warning_secs or 0;
    local to_remove = {};

    for key, entry in pairs(self.ActiveTimers) do
        if entry.type == 'ph' then
            local rem = self:GetRemaining(entry);

            -- Auto-remove PH timers well after expiry (grace period lets UI show "Spawned")
            if rem <= -PH_GRACE_SECS then
                to_remove[#to_remove + 1] = key;
            elseif not entry.alarm_fired then
                -- Fire alarm when countdown reaches the warning threshold
                if rem <= warn and rem > 0 and gSettings.alarm_on_ph_spawn then
                    gSounds:Play(gSettings.alarm_sound);
                    entry.alarm_fired = true;
                    if gSettings.tod_data[key] then gSettings.tod_data[key].alarm_fired = true; end
                    gSaveSettings();
                elseif rem <= 0 then
                    entry.alarm_fired = true;
                end
            end

        elseif entry.type == 'nm' then
            local status, until_open = self:GetNMWindowStatus(entry);

            -- Alarm: fire sound when window is about to open or just opened
            if not entry.alarm_fired then
                if status == 'waiting' and warn > 0 and until_open <= warn and until_open > 0 then
                    if gSettings.alarm_on_window then
                        gSounds:Play(gSettings.alarm_sound);
                        entry.alarm_fired = true;
                        if gSettings.tod_data[key] then gSettings.tod_data[key].alarm_fired = true; end
                        gSaveSettings();
                    end
                elseif status == 'open' then
                    if gSettings.alarm_on_window then gSounds:Play(gSettings.alarm_sound); end
                    entry.alarm_fired = true;
                    if gSettings.tod_data[key] then gSettings.tod_data[key].alarm_fired = true; end
                    gSaveSettings();
                end
            end

            -- Notify: independent chat message when countdown drops to notify_secs.
            -- Reuses status/until_open from the alarm check above — no second call needed.
            if entry.notify_secs and not entry.notify_fired then
                if status == 'waiting' and until_open <= entry.notify_secs then
                    local h = math.floor(until_open / 3600);
                    local m = math.floor((until_open % 3600) / 60);
                    local time_label = h > 0 and (m > 0
                        and string.format('%dhr %dmin', h, m)
                        or  string.format('%dhr', h))
                        or  string.format('%dmin', m);
                    print(chat.header('Eggs') .. chat.message(string.format(
                        '[%s] Eligible in ~%s.', entry.nm_name, time_label)));
                    entry.notify_fired = true;
                    if gSettings.tod_data[key] then gSettings.tod_data[key].notify_fired = true; end
                    gSaveSettings();
                elseif status == 'open' or status == 'expired' then
                    -- Already past — mark fired so we don't check again
                    entry.notify_fired = true;
                end
            end
        end
    end

    -- Remove expired PH timers outside the loop to avoid modifying while iterating
    for _, key in ipairs(to_remove) do
        self:RemoveTimer(key);
    end

    self:RefreshIdTargets();
    for key, e in pairs(self.IdTargets) do
        self:TickIdTarget(key, e, warn);
    end
end;

------------------------------------------------------------
-- ID Respawn Tracking, per-frame work
------------------------------------------------------------

-- Keep tracked mobs in step with the server data (also fixes entries saved
-- before a module changed their respawn). Cheap: the yaml is cached, and this
-- runs at most every 30 seconds.
tracker.RefreshIdTargets = function(self)
    local now_os = os.time();
    if (now_os - (self.LastIdRefresh or 0)) < 30 then return; end
    self.LastIdRefresh = now_os;

    local keys = {};
    for key in pairs(self.IdTargets) do keys[#keys + 1] = key; end
    for _, key in ipairs(keys) do self:RefreshIdRespawn(key); end
end;

-- Early-warning alarm, then the "window is up" message, for one dead mob.
tracker.AlarmIdTarget = function(self, key, e, warn)
    local rem  = self:IdRemaining(e);    -- follows the wave when it is known
    local play = gSettings.alarm_on_id_respawn ~= false;

    if not e.alarm_fired and warn > 0 and rem <= warn and rem > 0 then
        if play then gSounds:Play(gSettings.alarm_sound); end
        e.alarm_fired = true;
        self:SaveIdTarget(key);
        return;
    end

    if rem > 0 or e.due_notified then return; end

    if play and not e.alarm_fired then gSounds:Play(gSettings.alarm_sound); end
    print(chat.header('Eggs') .. chat.message(string.format(
        '[%s] respawn window is up.', e.name)));
    e.alarm_fired  = true;
    e.due_notified = true;
    self:SaveIdTarget(key);
end;

-- A dead mob has respawned once we are in its zone and its spawn slot is
-- occupied again by a living entity.
tracker.ConfirmIdRespawn = function(self, key, e)
    if self.CurrentZone ~= e.zone_id or not self.PresentIndex then return; end

    local st = self.PresentIndex[e.sp_index];
    if st == nil or DEAD_STATUSES[st] then return; end

    e.state        = 'alive';
    e.tod_os       = nil;
    e.tod_wall     = nil;
    e.alarm_fired  = false;
    e.due_notified = false;
    self:SaveIdTarget(key);
end;

tracker.TickIdTarget = function(self, key, e, warn)
    if e.state ~= 'dead' or not e.tod_os then return; end
    self:AlarmIdTarget(key, e, warn);
    self:ConfirmIdRespawn(key, e);
end;

------------------------------------------------------------
-- FormatTime
-- Formats a duration in seconds as HH:MM:SS or MM:SS.
------------------------------------------------------------
tracker.FormatTime = function(self, secs)
    if not secs or secs <= 0 then return '00:00'; end
    secs = math.floor(secs);
    local h = math.floor(secs / 3600);
    local m = math.floor((secs % 3600) / 60);
    local s = secs % 60;
    if h > 0 then
        return string.format('%02d:%02d:%02d', h, m, s);
    end
    return string.format('%02d:%02d', m, s);
end;

return tracker;
