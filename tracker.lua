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

local tracker = {};

-- Active timers in memory. Mirrors gSettings.tod_data but as live objects.
tracker.ActiveTimers = T{};

-- Last seen entity state per entity slot, used for death detection.
-- [entity_index] = { s=status, id=mob_id, n=name, sp=sp_index, c=poll_count }
tracker.LastStatus = {};

-- FFXI entity status values we consider "dead".
-- Status 3 confirmed as dead on LSB private server (e.g. Flying Manta: 1->3 on death).
local DEAD_STATUSES = { [3] = true };

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
-- GetRemaining
-- Returns seconds until a PH respawns (negative if already past).
------------------------------------------------------------
tracker.GetRemaining = function(self, entry)
    return entry.respawn_secs - (os.time() - entry.tod_os);
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
    local elapsed  = os.time() - entry.tod_os;
    local open_at  = entry.respawn_secs;
    local close_at = entry.window_secs;  -- 0 means no known close time

    if elapsed < open_at then
        -- Still in cooldown
        local until_close = (close_at > 0) and (close_at - elapsed) or nil;
        return 'waiting', open_at - elapsed, until_close;
    end

    if close_at > 0 and elapsed >= close_at then
        -- Past all windows
        return 'expired', 0, 0;
    end

    -- Window is open
    local until_close = (close_at > 0) and (close_at - elapsed) or nil;
    return 'open', 0, until_close;
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

    for idx = 1, 0x7FF do
        local name   = em:GetName(idx);
        local mob_id = em:GetServerId(idx);

        if name and name ~= '' and mob_id and mob_id > 0 then
            -- Entity is present in this slot
            local status   = em:GetStatus(idx);
            local sp_index = mob_id % 1024;
            local last     = self.LastStatus[idx];

            if last == nil then
                -- First poll for this entity — record initial state
                self.LastStatus[idx] = { s = status, id = mob_id, n = name, sp = sp_index, c = 1 };
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
                end

                last.s  = status;
                last.id = mob_id;
            end
        else
            -- Slot is empty — entity has despawned or we changed zones
            local last = self.LastStatus[idx];
            if last and last.id and last.id > 0 then
                if DEAD_STATUSES[last.s] then
                    -- Body of a dead mob cleared — timer already running, nothing to do
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
