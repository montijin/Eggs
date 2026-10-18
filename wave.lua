------------------------------------------------------------
-- wave.lua
-- Learns the server's mob respawn "wave" grid per zone and predicts repops.
--
-- The LSB/Phoenix map server does not spawn mobs the instant their timer
-- ends. Each zone runs a wave every 30s (SpawnHandler::Tick) and spawns any
-- mob whose respawn time is due within the next 15s. The wave grid is fixed
-- for the lifetime of the map server, but its phase is random per zone and
-- is re-rolled every time the server restarts.
--
-- We learn the phase by timing real respawns we see happen, then:
--     respawn_at = despawn_start + respawn_secs
--     repop      = first grid time (phase + 30k) >= respawn_at - 15s
--
-- Because the grid only changes when the server restarts, a learned phase is
-- still right on a later day. It is saved in wall-clock terms (Ashita's
-- high-resolution clock restarts every boot) and treated as a hint until new
-- spawns confirm it.
------------------------------------------------------------

local wave = {};

local PERIOD = 30.0;   -- kSpawnHandlerInterval
local WINDOW = 15.0;   -- kSpawnHandlerWindow (half the interval)

-- A saved phase drifts slowly against real time (the server's timer is not
-- disciplined by time sync), so trust it less as it ages and drop it after a
-- few days.
local SAVED_MAX_DAYS   = 3;
local SAVED_BASE_TOL   = 1.5;   -- seconds, same as a fresh sample
local SAVED_TOL_PER_DAY = 1.0;  -- extra seconds of allowed drift per day of age

-- LuaJIT (Ashita) has atan2; newer Lua only has the two-argument atan.
local atan2 = math.atan2 or function(y, x) return math.atan(y, x); end;

-- Per-zone state for this session, in memory only.
--   samples = { { t = hi-res secs, p = t % PERIOD }, ... } newest last
--   pending = outliers that may be a new grid after a server restart
--   phase / count / spread / locked = current estimate (hi-res clock domain)
--   via_saved      locked on 2 spawns because a saved phase agreed
--   prior_dropped  the saved phase was contradicted, ignore it
wave.Zones = {};

-- Phases kept between sessions: [zone_id] = { p = wall phase, t = os.time when
-- saved, n = spawns behind it }. Mirrors SavePath. Wall phase is
-- (server tick time as seen on this PC's clock) % 30.
wave.Saved    = {};
wave.SavePath = nil;    -- set by the addon; nil disables saving

------------------------------------------------------------
-- Now
-- Sub-second wall clock in seconds. Only differences and t % 30 are used,
-- so the epoch does not matter. Falls back to os.time() (1s resolution).
------------------------------------------------------------
wave.Now = function()
    local ok, c = pcall(function() return ashita.time.clock(); end);
    if ok and c and c.ms then return c.ms / 1000.0; end
    return os.time() + 0.0;
end;

-- Seam for tests.
wave.OsNow = function() return os.time(); end;

local function tol()         return (gSettings and gSettings.wave_tolerance)   or 1.5; end
local function min_samples() return (gSettings and gSettings.wave_min_samples) or 3;   end
local function saving_on()   return wave.SavePath ~= nil and not (gSettings and gSettings.wave_save == false); end

-- Signed circular difference a-b on the 30s ring, in (-15, 15].
local function cdiff(a, b)
    local d = (a - b) % PERIOD;
    if d > PERIOD / 2 then d = d - PERIOD; end
    return d;
end

-- Circular mean of values on the 30s ring.
local function cmean(vals)
    local sx, sy = 0, 0;
    for _, v in ipairs(vals) do
        local a = 2 * math.pi * v / PERIOD;
        sx = sx + math.cos(a);
        sy = sy + math.sin(a);
    end
    local a = atan2(sy, sx);
    if a < 0 then a = a + 2 * math.pi; end
    return a * PERIOD / (2 * math.pi);
end

------------------------------------------------------------
-- Wall clock calibration
-- Ashita's clock has no fixed epoch, so a phase measured on it means nothing
-- tomorrow. os.time() is real time but only whole seconds. Each time
-- os.time() ticks over between two polls we learn that the real second
-- boundary fell in that gap, which bounds  offset = wall - clock.  Every new
-- boundary narrows the bounds, so the offset converges to a few ms.
------------------------------------------------------------
wave.Wall = { lo = nil, hi = nil, prev_os = nil, prev_clock = nil };

wave.Calibrate = function(self, clock, os_now)
    local w = self.Wall;
    if w.prev_os then
        if os_now < w.prev_os then
            w.lo, w.hi = nil, nil;                       -- PC clock stepped back
        elseif os_now > w.prev_os then
            local lo, hi = os_now - clock, os_now - w.prev_clock;
            if w.lo and (lo > w.hi + 0.02 or hi < w.lo - 0.02) then
                w.lo, w.hi = lo, hi;                     -- clocks disagree: start over
            else
                w.lo = math.max(w.lo or lo, lo);
                w.hi = math.min(w.hi or hi, hi);
                if w.lo > w.hi then
                    local mid = (w.lo + w.hi) / 2;
                    w.lo, w.hi = mid, mid;
                end
            end
        end
    end
    w.prev_os, w.prev_clock = os_now, clock;
end;

-- wall = clock + offset. nil until the offset is known to within a second.
wave.WallOffset = function()
    local w = wave.Wall;
    if w.lo and w.hi and (w.hi - w.lo) < 1.0 then return (w.lo + w.hi) / 2; end
    return nil;
end;

------------------------------------------------------------
-- Saved phases
------------------------------------------------------------
-- The saved entry for a zone if it is still usable (not too old, not
-- contradicted this session). Returns the entry and its age in days.
local function saved_of(zone_id, z)
    local s = wave.Saved[zone_id];
    if not s or (z and z.prior_dropped) then return nil; end
    local age = (wave.OsNow() - s.t) / 86400.0;
    if age < 0 or age > SAVED_MAX_DAYS then return nil; end
    return s, age;
end

local function saved_tol(age_days) return SAVED_BASE_TOL + SAVED_TOL_PER_DAY * age_days; end

local function fmt_age(days)
    if days < 1 / 24 then return string.format('%d min', math.max(1, math.floor(days * 1440 + 0.5))); end
    if days < 1 then return string.format('%.0f h', days * 24); end
    return string.format('%.1f d', days);
end

-- Re-read the file, replacing the in-memory copy. Other game clients may
-- have saved zones since we last looked.
wave.LoadFile = function(self)
    if not self.SavePath then return; end
    local chunk = loadfile(self.SavePath);
    if not chunk then return; end
    local ok, t = pcall(chunk);
    if not (ok and type(t) == 'table') then return; end
    local out = {};
    for k, v in pairs(t) do
        if type(k) == 'number' and type(v) == 'table' and type(v.p) == 'number' and type(v.t) == 'number' then
            out[k] = { p = v.p, t = v.t, n = tonumber(v.n) or 0 };
        end
    end
    self.Saved = out;
end;

local function write_file(self)
    local lines = { 'return {' };
    local keys = {};
    for k in pairs(self.Saved) do keys[#keys + 1] = k; end
    table.sort(keys);
    for _, k in ipairs(keys) do
        local s = self.Saved[k];
        lines[#lines + 1] = string.format('    [%d] = { p = %.3f, t = %d, n = %d },', k, s.p, s.t, s.n or 0);
    end
    lines[#lines + 1] = '};';
    local f = io.open(self.SavePath, 'w');
    if not f then return false; end
    f:write(table.concat(lines, '\n') .. '\n');
    f:close();
    return true;
end

-- Save the zone's locked phase. Throttled unless `force`, since a locked
-- zone refreshes on every further sample.
wave.Persist = function(self, zone_id, force)
    if not saving_on() then return false; end
    local z, off = self.Zones[zone_id], wave.WallOffset();
    if not (z and z.locked and z.phase and off) then return false; end
    local now = self.OsNow();
    if not force and z.saved_at and (now - z.saved_at) < 20 then return false; end

    self:LoadFile();    -- keep zones other clients saved
    self.Saved[zone_id] = { p = (z.phase + off) % PERIOD, t = now, n = z.count };
    z.saved_at = now;
    return write_file(self);
end;

------------------------------------------------------------
-- Estimate
------------------------------------------------------------
local function zone_state(zone_id)
    local z = wave.Zones[zone_id];
    if not z then
        z = { samples = {}, pending = {}, phase = nil, count = 0, spread = nil, locked = false };
        wave.Zones[zone_id] = z;
    end
    return z;
end

-- Pick the tightest cluster of samples, ties going to the newest, and
-- average it. Samples outside the cluster (mobs spawned by scripts rather
-- than the wave) are simply ignored.
--
-- Three agreeing samples lock it. Two are enough when a saved phase from an
-- earlier session agrees; three that contradict the saved phase mean the
-- server restarted, so the saved phase is discarded.
local function estimate(z, zone_id)
    local s, n = z.samples, #z.samples;
    z.phase, z.count, z.spread, z.locked, z.via_saved = nil, 0, nil, false, false;
    if n == 0 then return; end

    local t = tol();
    local best, best_c = nil, 0;
    for i = 1, n do
        local c = 0;
        for j = 1, n do
            if math.abs(cdiff(s[j].p, s[i].p)) <= t then c = c + 1; end
        end
        if c >= best_c then best, best_c = s[i].p, c; end
    end

    local members = {};
    for j = 1, n do
        if math.abs(cdiff(s[j].p, best)) <= t then members[#members + 1] = s[j].p; end
    end

    local ph = cmean(members);
    local sp = 0;
    for _, v in ipairs(members) do sp = math.max(sp, math.abs(cdiff(v, ph))); end

    z.phase, z.count, z.spread = ph, #members, sp;
    z.locked = (#members >= min_samples());

    local saved, age = saved_of(zone_id, z);
    local off = wave.WallOffset();
    if saved and off then
        local matches = math.abs(cdiff((ph + off) % PERIOD, saved.p)) <= saved_tol(age);
        if z.locked and not matches then
            z.prior_dropped, z.saved_rejected = true, true;
        elseif (not z.locked) and #members >= 2 and matches then
            z.locked, z.via_saved = true, true;
        end
    end
end

------------------------------------------------------------
-- AddSample
-- Record one observed respawn (hi-res time t) in a zone.
-- Returns 'added', 'locked', 'confirmed' (locked early thanks to a saved
-- phase), 'duplicate', 'outlier', or 'regrid' (server restart detected).
------------------------------------------------------------
wave.AddSample = function(self, zone_id, t)
    local z = zone_state(zone_id);
    local p = t % PERIOD;
    local was_locked = z.locked;

    -- Mobs spawning on the same tick are one observation of the grid, not
    -- several. Requiring distinct moments keeps one burst from locking it.
    for i = #z.samples, 1, -1 do
        if math.abs(t - z.samples[i].t) < 5.0 then return 'duplicate'; end
    end

    if z.locked and math.abs(cdiff(p, z.phase)) > tol() + 0.5 then
        -- Off the known grid. One-offs are ignored; three tight ones in a
        -- row on a new phase mean the server restarted and re-rolled it.
        z.pending[#z.pending + 1] = { t = t, p = p };
        if #z.pending > 6 then table.remove(z.pending, 1); end

        if #z.pending >= 3 then
            local recent = { z.pending[#z.pending - 2], z.pending[#z.pending - 1], z.pending[#z.pending] };
            local tight = true;
            for i = 2, 3 do
                if math.abs(cdiff(recent[i].p, recent[1].p)) > tol() then tight = false; end
            end
            if tight then
                z.samples = { recent[1], recent[2], recent[3] };
                z.pending = {};
                z.prior_dropped = true;      -- a new grid means the old one is history
                estimate(z, zone_id);
                return 'regrid';
            end
        end
        return 'outlier';
    end

    z.pending = {};
    z.manual = nil;                     -- a real observation now backs it
    z.samples[#z.samples + 1] = { t = t, p = p };
    if #z.samples > 24 then table.remove(z.samples, 1); end
    estimate(z, zone_id);
    if z.locked and not was_locked then return z.via_saved and 'confirmed' or 'locked'; end
    return 'added';
end;

------------------------------------------------------------
-- SetManual
-- The user states the wave outright: ticks land at `wall_secs` and
-- `wall_secs + 30` seconds past the minute on this PC's clock. Stored as a
-- locked phase built from synthetic samples, so the normal machinery still
-- applies: real spawns that disagree will replace it (three of them = regrid).
-- Returns true, or false if the wall clock is not calibrated yet.
------------------------------------------------------------
wave.SetManual = function(self, zone_id, wall_secs, now_clock)
    local off = wave.WallOffset();
    if not off then return false; end

    local phase = ((wall_secs % 60) - off) % PERIOD;    -- hi-res clock domain
    local z = zone_state(zone_id);
    z.samples, z.pending = {}, {};
    z.prior_dropped, z.saved_rejected = true, nil;      -- the user's word beats a saved phase

    local base = now_clock - (now_clock % PERIOD) + phase;
    for k = min_samples(), 1, -1 do
        z.samples[#z.samples + 1] = { t = base - PERIOD * k, p = phase };
    end
    estimate(z, zone_id);
    z.manual = true;
    return true;
end;

------------------------------------------------------------
-- Reset
-- Forget one zone, or everything when zone_id is nil, including what was
-- saved to disk.
------------------------------------------------------------
wave.Reset = function(self, zone_id)
    if zone_id then
        self.Zones[zone_id] = nil;
    else
        self.Zones = {};
    end

    if self.SavePath then
        self:LoadFile();
        if zone_id then self.Saved[zone_id] = nil; else self.Saved = {}; end
        write_file(self);
    else
        if zone_id then self.Saved[zone_id] = nil; else self.Saved = {}; end
    end
end;

------------------------------------------------------------
-- Phase to predict with: this session's lock, else a usable saved phase.
-- Returns phase (hi-res clock domain), kind ('locked' | 'saved'), and for a
-- saved phase its age in days.
------------------------------------------------------------
local function phase_for(zone_id)
    local z = wave.Zones[zone_id];
    if z and z.locked and z.phase then return z.phase, 'locked'; end
    local saved, age = saved_of(zone_id, z);
    local off = wave.WallOffset();
    if saved and off then return (saved.p - off) % PERIOD, 'saved', age; end
    return nil;
end

------------------------------------------------------------
-- Predict
--   despawn_hr   hi-res time the server started the despawn (clock start)
--   respawn_secs the mob's respawn timer
-- Returns a table:
--   locked   true when the zone's wave phase is known this session
--   saved    true when it is predicted from an unconfirmed saved phase
--   at       predicted repop (hi-res secs), only when locked or saved
--   earliest first moment the mob can be picked up by a wave
--   latest   last moment it can be delayed to when the phase is unknown
------------------------------------------------------------
wave.Predict = function(self, zone_id, despawn_hr, respawn_secs, now)
    local earliest = despawn_hr + respawn_secs - WINDOW;
    local phase, kind = phase_for(zone_id);

    if not phase then
        return { locked = false, saved = false, earliest = earliest, latest = earliest + PERIOD };
    end

    -- A wave in the past cannot spawn it any more, so start from now.
    local from = math.max(earliest, now);
    local k    = math.ceil((from - phase) / PERIOD);
    return {
        locked = (kind == 'locked'), saved = (kind == 'saved'),
        at = phase + k * PERIOD, earliest = earliest, latest = earliest + PERIOD,
    };
end;

------------------------------------------------------------
-- RepopWall
-- The moment (real wall-clock seconds) a mob should come back:
--   the first wave tick at or after  despawn + respawn_secs - 15s.
-- Unlike Predict this ignores "now", so a mob that is overdue stays overdue
-- instead of being pushed to the next tick.
-- Returns time, kind ('locked' | 'saved'), or nil when this zone's wave is
-- not known or the wall clock is not calibrated yet.
------------------------------------------------------------
wave.RepopWall = function(self, zone_id, despawn_wall, respawn_secs)
    local off = wave.WallOffset();
    if not off then return nil; end
    local phase, kind = phase_for(zone_id);
    if not phase then return nil; end

    local wall_phase = (phase + off) % PERIOD;
    local earliest   = despawn_wall + respawn_secs - WINDOW;
    local k          = math.ceil((earliest - wall_phase) / PERIOD);
    return wall_phase + k * PERIOD, kind;
end;

-- Next wave tick at or after `now`, or nil while the phase is unknown.
wave.NextTick = function(self, zone_id, now)
    local z = self.Zones[zone_id];
    if not (z and z.locked) then return nil; end
    return z.phase + math.ceil((now - z.phase) / PERIOD) * PERIOD;
end;

-- One-line status for the UI and /eggs wave.
-- Returns the text, whether the wave is locked, and whether it is running
-- on an unconfirmed saved phase.
wave.Status = function(self, zone_id, now)
    local z = self.Zones[zone_id];
    local need = min_samples();

    if z and z.locked then
        local nxt = self:NextTick(zone_id, now);
        if z.manual then
            return string.format('Wave: set manually  next tick in %ds',
                math.max(0, math.floor((nxt - now) + 0.5))), true, false;
        end
        return string.format('Wave: locked%s (%d spawns, +/-%.1fs)  next tick in %ds',
            z.via_saved and ' from saved phase' or '', z.count, z.spread or 0,
            math.max(0, math.floor((nxt - now) + 0.5))), true, false;
    end

    local _, kind, age = phase_for(zone_id);
    if kind == 'saved' then
        return string.format('Wave: saved phase from %s ago, unconfirmed (%d/2 spawns seen)',
            fmt_age(age), math.min(2, z and z.count or 0)), false, true;
    end

    if not z or #z.samples == 0 then
        return string.format('Wave: learning (0/%d spawns seen)', need), false, false;
    end
    return string.format('Wave: learning (%d/%d spawns seen)', z.count, need), false, false;
end;

return wave;
