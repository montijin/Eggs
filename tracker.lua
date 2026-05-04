require('common');
local chat = require('chat');
------------------------------------------------------------
-- tracker.lua
-- Manages all active timer state.
--
-- Keys:
--   PH timers:  "ph:<zone_id>:<ph_name>"
--   NM timers:  "nm:<nm_name>"
--
-- Each entry:
--   type         = 'ph' | 'nm'
--   nm_name      = string
--   ph_name      = string (PH only)
--   zone_id      = number
--   respawn_secs = number   (PH: respawn time; NM: window open time)
--   window_secs  = number   (NM: window close time, 0 = unknown)
--   tod_os       = number   (os.time() of death)
--   alarm_fired  = bool
------------------------------------------------------------

local tracker = {};

tracker.ActiveTimers = T{};

------------------------------------------------------------
-- Restore timers from saved settings on load
------------------------------------------------------------
tracker.Initialize = function(self)
    self.ActiveTimers = T{};
    if not gSettings.tod_data then return; end
    local now     = os.time();
    local expired = {};
    for key, saved in pairs(gSettings.tod_data) do
        local elapsed = now - (saved.tod_os or 0);
        -- Drop PH timers that have already fully expired
        if saved.type == 'ph' and elapsed >= (saved.respawn_secs or 0) then
            expired[#expired+1] = key;
        -- Drop NM timers where the window has fully closed
        elseif saved.type == 'nm' and (saved.window_secs or 0) > 0
               and elapsed >= (saved.window_secs or 0) then
            expired[#expired+1] = key;
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
            };
        end
    end
    -- Clean up expired entries from persistent storage
    for _, key in ipairs(expired) do
        gSettings.tod_data[key] = nil;
    end
    if #expired > 0 then
        gSaveSettings();
    end
end;

------------------------------------------------------------
-- Record a death and start a timer
------------------------------------------------------------
tracker.RecordDeath = function(self, dtype, nm_name, ph_name, ph_mob_id, zone_id, respawn_secs, window_secs, tod_os_override)
    local key;
    if dtype == 'ph' then
        -- Key by mob_id so each individual PH has its own timer
        local mid = ph_mob_id or 0;
        key = string.format('ph:%d', mid);
    else
        local safe = nm_name:gsub('[^%w]', '_');
        key = string.format('nm:%s', safe);
    end

    -- The server starts the respawn clock when the body despawns, not when HP hits 0.
    -- We add a fixed offset to compensate for the body despawn delay.
    -- Only applied to auto-detected deaths, not manual /eggs tod entries.
    local DESPAWN_OFFSET = gSettings.despawn_offset or 10;
    local tod = tod_os_override or (os.time() + DESPAWN_OFFSET);
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
    };
    self.ActiveTimers[key] = entry;

    -- When a PH dies, clear its confirmed state so it shows as
    -- unconfirmed after respawn until the player targets it
    if dtype == 'ph' and ph_mob_id and ph_mob_id > 0 then
        if not gSettings.ph_confirmed then gSettings.ph_confirmed = {}; end
        gSettings.ph_confirmed[ph_mob_id] = nil;
    end

    -- Persist to settings
    gSettings.tod_data[key] = {
        type         = dtype,
        nm_name      = nm_name,
        ph_name      = ph_name,
        ph_mob_id    = ph_mob_id,
        zone_id      = zone_id,
        respawn_secs = respawn_secs,
        window_secs  = window_secs or 0,
        tod_os       = tod,
        alarm_fired  = false,
    };
    gSaveSettings();

    local label = dtype == 'ph' and (ph_name or 'PH') or nm_name;
    local tod_str = os.date('%m/%d/%Y %H:%M:%S', tod);
    print(chat.header('Eggs') .. chat.message(
        string.format('[%s] died at %s. Timer started (%ds respawn).', label, tod_str, respawn_secs)));
end;

------------------------------------------------------------
-- Remove a timer
------------------------------------------------------------
tracker.RemoveTimer = function(self, key)
    self.ActiveTimers[key] = nil;
    gSettings.tod_data[key] = nil;
    gSaveSettings();
end;

------------------------------------------------------------
-- Seconds remaining until respawn (PH) or window opens (NM)
-- Negative means it already passed.
------------------------------------------------------------
tracker.GetRemaining = function(self, entry)
    local elapsed = os.time() - entry.tod_os;
    return entry.respawn_secs - elapsed;
end;

------------------------------------------------------------
-- NM window status
-- Returns: status ('waiting'|'open'|'expired'), secs_until_open, secs_until_close
------------------------------------------------------------
tracker.GetNMWindowStatus = function(self, entry)
    local elapsed     = os.time() - entry.tod_os;
    local open_at     = entry.respawn_secs;
    local close_at    = entry.window_secs;   -- 0 = no known close time

    if elapsed < open_at then
        local until_close = (close_at > 0) and (close_at - elapsed) or nil;
        return 'waiting', open_at - elapsed, until_close;
    elseif close_at > 0 and elapsed >= close_at then
        return 'expired', 0, 0;
    else
        local until_close = (close_at > 0) and (close_at - elapsed) or nil;
        return 'open', 0, until_close;
    end
end;

------------------------------------------------------------
-- Poll entity statuses each frame to detect deaths
-- Called from d3d_present via gui:Render()
------------------------------------------------------------
tracker.LastStatus = {};  -- [entity_index] = last known status

-- FFXI entity status values (confirmed on LSB private server):
--   0 = Idle/Alive
--   1 = Engaged in combat
--   3 = Dead (confirmed: Flying Manta transitions 1->3 on death)
local DEAD_STATUSES = { [3]=true };

tracker.PollEntities = function(self)
    local em      = AshitaCore:GetMemoryManager():GetEntity();
    local zone_id = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);

    for idx = 1, 0x7FF do
        local name   = em:GetName(idx);
        local mob_id = em:GetServerId(idx);

        if name and name ~= '' and mob_id and mob_id > 0 then
            local status   = em:GetStatus(idx);
            local sp_index = mob_id % 1024;
            local last     = self.LastStatus[idx];

            if last == nil then
                -- First time seeing this entity - record with poll count
                self.LastStatus[idx] = { s = status, id = mob_id, n = name, sp = sp_index, c = 1 };
            else
                last.c = (last.c or 0) + 1;

                -- Debug: print EVERY status change for PH mobs
                if gSettings.debug_mode and last.s ~= status then
                    local is_ph = gNmData:GetNMForPH(sp_index);
                    if is_ph or (gNmData.NMs and gNmData.NMs[name]) then
                        print(chat.header('Eggs') .. chat.message(string.format(
                            'STATUS: idx=%d %s mob_id=%d sp=%d  %d -> %d  (ph=%s)',
                            idx, name, mob_id, sp_index, last.s, status,
                            is_ph or 'NM')));
                    end
                end

                -- Detect transition INTO a dead status
                if DEAD_STATUSES[status] and not DEAD_STATUSES[last.s] then
                    if gSettings.debug_mode then
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
            -- Slot empty - entity despawned (or zone transition artifact)
            local last = self.LastStatus[idx];
            if last and last.id and last.id > 0 then
                local is_debug = gSettings and gSettings.debug_mode;
                if DEAD_STATUSES[last.s] then
                    -- Dead body slot cleared - no action needed, timer already running
                    if is_debug then
                        local is_ph = gNmData:GetNMForPH(last.sp or 0);
                        if is_ph then
                            print(chat.header('Eggs') .. chat.message(string.format(
                                'BodySlotCleared: idx=%d name=%s (timer already running)',
                                idx, last.n or '?')));
                        end
                    end
                elseif (last.c or 0) >= 3 then
                    -- Disappeared without dying (e.g. de-popped NM)
                    if gSettings.debug_mode then
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

tracker.CheckAndRecordDeath = function(self, entity_index, entity_name, mob_id, sp_index, zone_id, from_despawn)
    local dbg = gSettings and gSettings.debug_mode;
    local nm_name = gNmData:GetNMForPH(sp_index);

    if dbg then
        print(chat.header('Eggs') .. chat.message(string.format(
            'CheckDeath: name=%s sp_idx=%d ph_match=%s despawn=%s',
            entity_name, sp_index, nm_name or 'none', tostring(from_despawn or false))));
    end

    if from_despawn then
        -- Body just despawned - update existing timer's tod_os to now
        -- (server starts respawn clock at body despawn, not at death)
        if nm_name then
            local nm_entry = gNmData:GetNM(nm_name) or gNmData:GetNMAnyZone(nm_name);
            if nm_entry then
                local safe = nm_name:gsub('[^%w]', '_');
                local ph_key = string.format('ph:%d', mob_id);
                if self.ActiveTimers[ph_key] then
                    self.ActiveTimers[ph_key].tod_os = os.time();
                    if gSettings.tod_data and gSettings.tod_data[ph_key] then
                        gSettings.tod_data[ph_key].tod_os = os.time();
                        gSaveSettings();
                    end
                    if dbg then
                        print(chat.header('Eggs') .. chat.message(
                            'Body despawned - timer reset to now for ' .. nm_name));
                    end
                end
            end
        end
        return;
    end

    if nm_name then
        -- Notify popup regardless of tracking
        local ok, err = pcall(function()
            gGui:ShowPHPopup(nm_name, entity_name, mob_id);
        end);
        if not ok and dbg then
            print(chat.header('Eggs') .. chat.error('ShowPHPopup error: ' .. tostring(err)));
        end

        -- Check tracking
        local is_tracked = gSettings.tracked and gSettings.tracked[nm_name];
        if dbg then
            print(chat.header('Eggs') .. chat.message(string.format(
                'NM=%s tracked=%s', nm_name, tostring(is_tracked ~= nil))));
        end

        if is_tracked then
            local nm_entry = gNmData:GetNM(nm_name);
            if dbg then
                print(chat.header('Eggs') .. chat.message(string.format(
                    'nm_entry=%s', nm_entry and 'found' or 'NIL - not in current zone!')));
            end

            if not nm_entry then
                -- Try loading from AllNMs (cross-zone)
                nm_entry = gNmData:GetNMAnyZone(nm_name);
                if dbg then
                    print(chat.header('Eggs') .. chat.message(string.format(
                        'nm_entry from AllNMs=%s', nm_entry and 'found' or 'still nil')));
                end
            end

            if nm_entry then
                local ph_respawn = 300;
                if nm_entry.PHs then
                    for _, ph in ipairs(nm_entry.PHs) do
                        if ph.Index == sp_index then
                            local rt = ph.RespawnTime or 0;
                            ph_respawn = (rt > 0) and rt or 300;
                            if dbg then
                                print(chat.header('Eggs') .. chat.message(string.format(
                                    'PH match: Index=%d RespawnTime=%d',
                                    ph.Index, ph_respawn)));
                            end
                            break;
                        end
                    end
                end
                if dbg then
                    print(chat.header('Eggs') .. chat.message(string.format(
                        'Calling RecordDeath: ph=%s nm=%s respawn=%d',
                        entity_name, nm_name, ph_respawn)));
                end
                self:RecordDeath('ph', nm_name, entity_name, mob_id, zone_id, ph_respawn, 0);
            end
        end
        return;
    end

    -- Is this the NM itself?
    local nm_entry = gNmData:GetNM(entity_name);
    if not nm_entry then nm_entry = gNmData:GetNMAnyZone(entity_name); end

    if nm_entry and gSettings.tracked and gSettings.tracked[entity_name] then
        -- Clear confirmed-alive state since the NM just died
        if gGui and gGui.NMConfirmedUp then
            gGui.NMConfirmedUp[entity_name] = nil;
        end
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
                'NM death: %s type=%s window=%d-%d',
                entity_name, nm_entry.NMType or '?', window_min, window_max)));
        end
        -- Only start NM cooldown timer if there's actually a cooldown
        -- True lottery NMs (like King Arthro) have no cooldown - PHs resume immediately
        if window_min > 0 or window_max > 0 then
            self:RecordDeath('nm', entity_name, nil, 0, zone_id, window_min, window_max);
        else
            print(chat.header('Eggs') .. chat.message(
                '[' .. entity_name .. '] died. PHs resume immediately (no cooldown).'));
        end

        local to_del = {};
        for key, entry in pairs(self.ActiveTimers) do
            if entry.nm_name == entity_name and entry.type == 'ph' then
                to_del[#to_del + 1] = key;
            end
        end
        for _, k in ipairs(to_del) do self:RemoveTimer(k); end
    end
end;

------------------------------------------------------------
-- Alarm tick - called every frame from gui:Render()
------------------------------------------------------------
tracker.Tick = function(self)
    local warn       = gSettings.alarm_warning_secs or 0;
    local to_remove  = {};
    local PH_GRACE   = 120;  -- seconds after respawn before auto-clearing PH timer

    for key, entry in pairs(self.ActiveTimers) do
        if entry.type == 'ph' then
            local rem = self:GetRemaining(entry);
            -- Auto-remove PH timers well after they've expired (grace period)
            if rem <= -PH_GRACE then
                to_remove[#to_remove+1] = key;
            elseif not entry.alarm_fired then
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
            if not entry.alarm_fired then
                local status, until_open, _ = self:GetNMWindowStatus(entry);
                if status == 'waiting' then
                    if warn > 0 and until_open <= warn and until_open > 0 then
                        if gSettings.alarm_on_window then
                            gSounds:Play(gSettings.alarm_sound);
                            entry.alarm_fired = true;
                            if gSettings.tod_data[key] then gSettings.tod_data[key].alarm_fired = true; end
                            gSaveSettings();
                        end
                    end
                elseif status == 'open' then
                    if gSettings.alarm_on_window then
                        gSounds:Play(gSettings.alarm_sound);
                    end
                    entry.alarm_fired = true;
                    if gSettings.tod_data[key] then gSettings.tod_data[key].alarm_fired = true; end
                    gSaveSettings();
                end
            end
        end
    end

    -- Remove expired PH timers outside the loop to avoid iterator invalidation
    for _, key in ipairs(to_remove) do
        self:RemoveTimer(key);
    end
end;

------------------------------------------------------------
-- Format seconds as HH:MM:SS or MM:SS
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