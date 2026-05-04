addon.name    = 'Eggs';
addon.author  = 'MNT';
addon.desc    = 'NM Placeholder tracker and respawn timer';
addon.version = '1.0';

require('common');
local chat     = require('chat');
local imgui    = require('imgui');

------------------------------------------------------------
-- Settings: stored as JSON via ashita.settings
------------------------------------------------------------
local SETTINGS_PATH = string.format('%sconfig/addons/%s/settings.lua',
    AshitaCore:GetInstallPath(), addon.name);

local default_settings = {
    tracker_pos        = { 100, 100 },
    tracker_visible    = true,
    ph_detail_pos      = { 400, 100 },
    ph_detail_visible  = false,
    settings_pos       = { 200, 200 },
    settings_visible   = false,
    nm_browser_pos     = { 300, 150 },
    nm_browser_visible = false,
    alarm_sound        = 'chime',
    alarm_warning_secs = 60,
    alarm_on_window    = true,
    alarm_on_ph_spawn  = true,
    tracked            = {},
    tod_data           = {},
    favorites          = {},
    debug_mode         = false,
    short_ids          = false,
    alarm_volume       = 100,
    ui_scale           = 1.0,
    ph_alive_timeout   = 60,   -- seconds after last targeting before status shifts to Unknown
    confirm_untrack    = true, -- require confirmation before removing a tracked NM
    despawn_offset     = 10,   -- seconds added to auto-detected death time to account for body despawn delay
};

-- Serialize a Lua table to a simple string format
local function serialize(val, depth)
    depth = depth or 0;
    local indent  = string.rep('    ', depth);
    local indent1 = string.rep('    ', depth + 1);
    local t = type(val);
    if t == 'string'  then return string.format('%q', val); end
    if t == 'number'  then return tostring(val); end
    if t == 'boolean' then return tostring(val); end
    if t == 'table'   then
        local parts = {};
        local is_array = (#val > 0);
        if is_array then
            for _, v in ipairs(val) do
                parts[#parts + 1] = indent1 .. serialize(v, depth + 1);
            end
        else
            for k, v in pairs(val) do
                local key;
                if type(k) == 'string' then
                    key = '[' .. string.format('%q', k) .. ']';
                else
                    key = '[' .. tostring(k) .. ']';
                end
                parts[#parts + 1] = indent1 .. key .. ' = ' .. serialize(v, depth + 1);
            end
        end
        if #parts == 0 then return '{}'; end
        return '{\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. '}';
    end
    return 'nil';
end

local function save_settings()
    local dir = string.format('%sconfig/addons/%s/', AshitaCore:GetInstallPath(), addon.name);
    ashita.fs.create_directory(dir);
    local f = io.open(SETTINGS_PATH, 'w');
    if f then
        f:write('return ' .. serialize(gSettings) .. ';');
        f:close();
    end
end

local function load_settings()
    if ashita.fs.exists(SETTINGS_PATH) then
        local loader, err = loadfile(SETTINGS_PATH);
        if loader then
            local ok, loaded = pcall(loader);
            if ok and type(loaded) == 'table' then
                for k, v in pairs(default_settings) do
                    if loaded[k] == nil then loaded[k] = v; end
                end
                return loaded;
            end
        end
    end
    -- Return deep copy of defaults
    local copy = {};
    for k, v in pairs(default_settings) do
        if type(v) == 'table' then
            local t = {};
            for k2, v2 in pairs(v) do t[k2] = v2; end
            copy[k] = t;
        else
            copy[k] = v;
        end
    end
    return copy;
end

------------------------------------------------------------
-- Load modules (after globals are set up)
------------------------------------------------------------
local nm_data  = require('nm_data');
local gui      = require('gui');
local tracker  = require('tracker');
local sounds   = require('sounds');
local importer = require('import');

------------------------------------------------------------
-- Expose globals for cross-module access
------------------------------------------------------------
gSettings     = load_settings();
gZoning       = false;
gZoneFrames   = 0;
gLastZone     = 0;
gPollFrame    = 0;
gSaveSettings = save_settings;   -- callable from other modules
gNmData       = nm_data;
gTracker      = tracker;
gSounds       = sounds;
gGui          = gui;

------------------------------------------------------------
local function reload_zone_data()
    local zone = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
    nm_data:Load(zone);
end;

------------------------------------------------------------
-- /eggs command handler
------------------------------------------------------------
local function handle_command(args)
    local cmd = (args[1] or ''):lower();

    if cmd == 'help' or cmd == '' then
        print(chat.header('Eggs') .. chat.message('/eggs show/hide       Show/hide tracker window'));
        print(chat.header('Eggs') .. chat.message('/eggs browser         Open NM browser'));
        print(chat.header('Eggs') .. chat.message('/eggs settings        Open settings'));
        print(chat.header('Eggs') .. chat.message('/eggs import          Import NM data from LSB scripts'));
        print(chat.header('Eggs') .. chat.message('/eggs clear           Clear all timer data'));
        print(chat.header('Eggs') .. chat.message('/eggs debug           Toggle debug mode'));
        print(chat.header('Eggs') .. chat.message('/eggs deathtime <NM Name>  Show stored ToD for a tracked NM'));
        print(chat.header('Eggs') .. chat.message('/eggs track <NM Name>  Start tracking an NM'));
        print(chat.header('Eggs') .. chat.message('/eggs fav <NM Name>   Add/remove NM from favorites'));
        print(chat.header('Eggs') .. chat.message('/eggs loot <NM Name>  Show loot table for an NM'));
        print(chat.header('Eggs') .. chat.message('/eggs tod <NM Name>                      Record NM death now'));
        print(chat.header('Eggs') .. chat.message('/eggs tod HH:MM:SS <NM Name>             Record NM death at time today'));
        print(chat.header('Eggs') .. chat.message('/eggs tod HH:MM:SS MM/DD/YYYY <NM Name>  Record NM death at specific date and time'));
        print(chat.header('Eggs') .. chat.message('/eggs <NM Name>       Open PH detail (works for any zone)'));
    elseif cmd == 'show' then
        gSettings.tracker_visible = true;
        save_settings();
    elseif cmd == 'hide' then
        gSettings.tracker_visible = false;
        save_settings();
    elseif cmd == 'settings' then
        gSettings.settings_visible = not gSettings.settings_visible;
        save_settings();
    elseif cmd == 'browser' then
        gSettings.nm_browser_visible = not gSettings.nm_browser_visible;
        if gSettings.nm_browser_visible then nm_data:LoadAllForBrowser(); end
        save_settings();
    elseif cmd == 'import' then
        print(chat.header('Eggs') .. chat.message('Running import...'));
        importer:Run();
    elseif cmd == 'debug' then
        gSettings.debug_mode = not gSettings.debug_mode;
        save_settings();
        print(chat.header('Eggs') .. chat.message(
            'Debug mode: ' .. (gSettings.debug_mode and 'ON' or 'OFF')));
        if gSettings.debug_mode then
            print(chat.header('Eggs') .. chat.message(
                'Kill a PH mob to see its entity index, mob ID and sp_index.'));
            print(chat.header('Eggs') .. chat.message(
                'Target a mob to see its PH lookup result.'));
            -- Memory snapshot on enable
            local mem_kb = collectgarbage('count');
            local timer_count  = 0; for _ in pairs(gTracker.ActiveTimers) do timer_count = timer_count + 1; end
            local track_count  = 0; for _ in pairs(gSettings.tracked)      do track_count  = track_count  + 1; end
            local cache_count  = 0; if gTracker and gTracker.LastStatus then for _ in pairs(gTracker.LastStatus) do cache_count = cache_count + 1; end end
            print(chat.header('Eggs') .. chat.message(string.format(
                'Lua heap: %.1f KB | Active timers: %d | Tracked NMs: %d | Entity cache: %d slots',
                mem_kb, timer_count, track_count, cache_count)));
        end
    elseif cmd == 'clear' then
        gSettings.tod_data = {};
        gTracker.ActiveTimers = T{};
        save_settings();
        print(chat.header('Eggs') .. chat.message('All timer data cleared.'));
    elseif cmd == 'tod' then
        -- /eggs tod <NM Name>              -- ToD = now
        -- /eggs tod HH:MM:SS <NM Name>     -- ToD = specified time today
        if not nm_data.AllNMsLoaded then nm_data:LoadAllForBrowser(); end

        -- Parse: /eggs tod [HH:MM[:SS]] [-N] <NM Name>
        --   HH:MM:SS [AM|PM]  optional time of death (defaults to now)
        local tod_os = nil;
        local name_start = 2;

        local time_str = args[2] or '';
        local h, m, s = time_str:match('^(%d%d?):(%d%d):(%d%d)$');
        if not h then h, m = time_str:match('^(%d%d?):(%d%d)$'); s = '0'; end
        if h then
            name_start = 3;
            h, m, s = tonumber(h), tonumber(m), tonumber(s or 0);

            -- Check for AM/PM modifier as next standalone arg
            local ampm_arg = (args[name_start] or ''):lower();
            if ampm_arg == 'am' or ampm_arg == 'pm' then
                if ampm_arg == 'am' then
                    if h == 12 then h = 0; end        -- 12:xx AM -> 00:xx
                elseif ampm_arg == 'pm' then
                    if h ~= 12 then h = h + 12; end   -- 12:xx PM stays 12:xx
                end
                name_start = name_start + 1;
            end

            -- Check next arg for an explicit date: MM/DD/YYYY
            local date_arg = args[name_start] or '';
            local mon, day, yr = date_arg:match('^(%d%d?)/(%d%d?)/(%d%d%d%d)$');
            if mon then
                name_start = name_start + 1;
                local t = { year=tonumber(yr), month=tonumber(mon), day=tonumber(day),
                            hour=h, min=m, sec=s };
                tod_os = os.time(t);
            else
                -- No date given — assume today, but if result is in the future assume yesterday
                local t = os.date('*t');
                t.hour = h; t.min = m; t.sec = s;
                tod_os = os.time(t);
                if tod_os > os.time() then tod_os = tod_os - 86400; end
            end
        end

        local nm_name = table.concat(args, ' ', name_start);
        if nm_name == '' then
            print(chat.header('Eggs') .. chat.message('Usage: /eggs tod <NM Name>'));
            print(chat.header('Eggs') .. chat.message('       /eggs tod HH:MM:SS [AM|PM] <NM Name>'));
            print(chat.header('Eggs') .. chat.message('       /eggs tod HH:MM:SS [AM|PM] MM/DD/YYYY <NM Name>'));
            goto done;
        end

        local nm = nm_data:GetNMAnyZone(nm_name);
        if not nm then
            print(chat.header('Eggs') .. chat.error('NM not found: ' .. nm_name));
            goto done;
        end

        -- Auto-track if not already tracked
        if not gSettings.tracked then gSettings.tracked = {}; end
        if not gSettings.tracked[nm.Name] then
            gSettings.tracked[nm.Name] = { alarm = true };
            print(chat.header('Eggs') .. chat.message('Now tracking: ' .. nm.Name));
        end

        local window_min, window_max;
        if nm.NMType == 'timed_spawn' then
            window_min = nm.WindowMin or 0;
            window_max = nm.WindowMax or 0;
        else
            -- Lottery NM: use cooldown as the timer
            window_min = nm.Cooldown or 0;
            window_max = 0;
        end

        if window_min == 0 and window_max == 0 then
            if nm.NMType == 'timed_spawn' then
                print(chat.header('Eggs') .. chat.error(nm.Name .. ' has no window data. Try running /eggs import to regenerate data.'));
            else
                print(chat.header('Eggs') .. chat.message(
                    nm.Name .. ' has no cooldown (True Lottery). PHs resume immediately — nothing to track.'));
            end
            goto done;
        end

        -- Clear any existing PH timers for this NM (same as organic NM death)
        local to_del = {};
        for key, entry in pairs(gTracker.ActiveTimers) do
            if entry.nm_name == nm.Name and entry.type == 'ph' then
                to_del[#to_del + 1] = key;
            end
        end
        for _, k in ipairs(to_del) do gTracker:RemoveTimer(k); end

        local zone_id = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
        gTracker:RecordDeath('nm', nm.Name, nil, 0, zone_id, window_min, window_max, tod_os);

        ::done::
    elseif cmd == 'deathtime' then
        local nm_name = table.concat(args, ' ', 2);
        if nm_name == '' then
            print(chat.header('Eggs') .. chat.message('Usage: /eggs deathtime <NM Name>'));
        else
            local key = 'nm:' .. nm_name:gsub('[^%w]', '_');
            local entry = gSettings.tod_data and gSettings.tod_data[key];
            -- Case-insensitive search if exact key not found
            if not entry and gSettings.tod_data then
                local lower = nm_name:lower();
                for k, v in pairs(gSettings.tod_data) do
                    if k:lower() == 'nm:' .. lower:gsub('[^%w]', '_') then
                        entry = v; break;
                    end
                end
            end
            if not entry then
                print(chat.header('Eggs') .. chat.message('No ToD recorded for: ' .. nm_name));
            else
                local t = os.date('*t', entry.tod_os);
                print(chat.header('Eggs') .. chat.message(string.format(
                    '[%s] ToD: %02d/%02d/%04d %02d:%02d:%02d',
                    nm_name, t.month, t.day, t.year, t.hour, t.min, t.sec)));
            end
        end
    elseif cmd == 'track' then
        local nm_name = table.concat(args, ' ', 2);
        if nm_name == '' then
            print(chat.header('Eggs') .. chat.message('Usage: /eggs track <NM Name>'));
        else
            if not nm_data.AllNMsLoaded then nm_data:LoadAllForBrowser(); end
            local nm = nm_data:GetNMAnyZone(nm_name);
            if not nm then
                print(chat.header('Eggs') .. chat.error('NM not found: ' .. nm_name));
            elseif nm.NMType == 'loot_only' then
                print(chat.header('Eggs') .. chat.error(nm.Name .. ' cannot be tracked (popped NM).'));
            else
                if not gSettings.tracked then gSettings.tracked = {}; end
                if gSettings.tracked[nm.Name] then
                    print(chat.header('Eggs') .. chat.message('Already tracking: ' .. nm.Name));
                else
                    gSettings.tracked[nm.Name] = { alarm = true };
                    save_settings();
                    print(chat.header('Eggs') .. chat.message('Now tracking: ' .. nm.Name));
                end
            end
        end
    elseif cmd == 'loot' then
        local nm_name = table.concat(args, ' ', 2);
        if nm_name == '' then
            print(chat.header('Eggs') .. chat.message('Usage: /eggs loot <NM Name>'));
        else
            if not nm_data.AllNMsLoaded then nm_data:LoadAllForBrowser(); end
            gui:ShowLootWindow(nm_name);
        end
    elseif cmd == 'fav' then
        local nm_name = table.concat(args, ' ');
        if nm_name ~= '' then
            if not gSettings.favorites then gSettings.favorites = {}; end
            if gSettings.favorites[nm_name] then
                gSettings.favorites[nm_name] = nil;
                print(chat.header('Eggs') .. chat.message('Removed from favorites: ' .. nm_name));
            else
                gSettings.favorites[nm_name] = true;
                print(chat.header('Eggs') .. chat.message('Added to favorites: ' .. nm_name));
            end
            save_settings();
        end
    else
        local nm_name = table.concat(args, ' ');
        if nm_name ~= '' then
            -- Load all zones so cross-zone lookup works
            if not nm_data.AllNMsLoaded then nm_data:LoadAllForBrowser(); end
            gui:SetDetailTarget(nm_name);
            if gSettings.ph_detail_visible then
                save_settings();
            end
        end
    end
end;

------------------------------------------------------------
-- Ashita event hooks
------------------------------------------------------------
ashita.events.register('load', 'eggs_load', function()
    reload_zone_data();
    tracker:Initialize();
    sounds:Initialize();
    gui:Initialize();
    nm_data:LoadAllForBrowser();
    print(chat.header('Eggs') .. chat.message(
        string.format('v%s loaded. /eggs help for commands.', addon.version)));
end);

ashita.events.register('unload', 'eggs_unload', function()
    save_settings();
end);

ashita.events.register('command', 'eggs_command', function(e)
    local args = e.command:args();
    if #args == 0 or args[1]:lower() ~= '/eggs' then return; end
    e.blocked = true;
    table.remove(args, 1);
    handle_command(args);
end);

ashita.events.register('d3d_present', 'eggs_present', function()
    -- Detect zoning by watching player entity (index 0x400 = self)
    -- Player entity name clears the moment zoning begins
    local em = AshitaCore:GetMemoryManager():GetEntity();
    local player_name = em:GetName(0x400);
    local is_zoning = (not player_name or player_name == '');

    if is_zoning and not gZoning then
        -- Just started zoning - clear LastStatus immediately
        gZoning = true;
        tracker.LastStatus = {};
    elseif not is_zoning and gZoning then
        -- Finished zoning - wait a bit more before resuming
        gZoneFrames = (gZoneFrames or 0) + 1;
        if gZoneFrames >= 60 then
            gZoning     = false;
            gZoneFrames = 0;
            tracker.LastStatus = {};
        end
    elseif not is_zoning then
        gZoneFrames = 0;
    end

    -- Don't poll entities while zoning
    if not gZoning then
        gPollFrame = (gPollFrame or 0) + 1;
        if gPollFrame >= 6 then
            gPollFrame = 0;
            tracker:PollEntities();
        end
        local targetMgr = AshitaCore:GetMemoryManager():GetTarget();
        local targetIdx = targetMgr:GetTargetIndex(0);
        if targetIdx ~= gui.CurrentTarget then
            gui:HandleTargetChange(targetIdx);
        end
    end
    gui:Render();
end);

ashita.events.register('packet_in', 'eggs_packet_in', function(e)
    if e.id == 0x00A then
        local zone = struct.unpack('H', e.data, 0x30 + 1);
        if zone and zone > 0 then
            nm_data:Load(zone);
            -- Reload AllNMs for cross-zone lookups (detail window, etc.)
            nm_data.AllNMsLoaded = false;
            nm_data:LoadAllForBrowser();
        end
        -- Extend suppression from packet side too
        gZoning     = true;
        gZoneFrames = math.max(gZoneFrames, 300);
    end
end);

ashita.events.register('target_change', 'eggs_target_change', function(target_index)
    gui:HandleTargetChange(target_index);
end);
