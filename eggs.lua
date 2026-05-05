------------------------------------------------------------
-- Eggs - NM Placeholder Tracker for Ashita v4
-- Author: MNT
-- Tracks placeholder mobs, respawn windows, and NM timers.
------------------------------------------------------------
addon.name    = 'Eggs';
addon.author  = 'MNT';
addon.desc    = 'NM Placeholder tracker and respawn timer';
addon.version = '1.0';

require('common');
local chat     = require('chat');
local imgui    = require('imgui');

------------------------------------------------------------
-- Settings
-- Stored as a Lua file at config/addons/Eggs/settings.lua
-- Loaded on startup, saved on any change.
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
    alarm_on_window    = true,   -- fire alarm when NM window opens
    alarm_on_ph_spawn  = true,   -- fire alarm when PH respawns
    tracked            = {},
    tod_data           = {},
    favorites          = {},
    debug_mode         = false,
    short_ids          = false,
    alarm_volume       = 100,
    ui_scale           = 1.0,
    ph_alive_timeout   = 60,     -- seconds after targeting before PH shifts to Unknown
    confirm_untrack    = true,   -- ask for confirmation before removing a tracked NM
    despawn_offset     = 10,     -- seconds added to auto-detected death to account for body despawn delay
};

-- Recursively serialize a Lua value to a pretty-printed string.
-- Used to write settings.lua in a human-readable format.
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
        if #val > 0 then
            -- Array-like table: use ipairs for ordered output
            for _, v in ipairs(val) do
                parts[#parts + 1] = indent1 .. serialize(v, depth + 1);
            end
        else
            -- Dictionary table: use pairs
            for k, v in pairs(val) do
                local key = type(k) == 'string'
                    and ('[' .. string.format('%q', k) .. ']')
                    or  ('[' .. tostring(k) .. ']');
                parts[#parts + 1] = indent1 .. key .. ' = ' .. serialize(v, depth + 1);
            end
        end
        if #parts == 0 then return '{}'; end
        return '{\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. '}';
    end
    return 'nil';
end

-- Write current settings to disk.
local function save_settings()
    local dir = string.format('%sconfig/addons/%s/', AshitaCore:GetInstallPath(), addon.name);
    ashita.fs.create_directory(dir);
    local f = io.open(SETTINGS_PATH, 'w');
    if not f then return; end
    f:write('return ' .. serialize(gSettings) .. ';');
    f:close();
end

-- Load settings from disk, falling back to defaults for any missing keys.
local function load_settings()
    if ashita.fs.exists(SETTINGS_PATH) then
        local loader = loadfile(SETTINGS_PATH);
        if loader then
            local ok, loaded = pcall(loader);
            if ok and type(loaded) == 'table' then
                -- Fill in any keys added since the settings file was last saved
                for k, v in pairs(default_settings) do
                    if loaded[k] == nil then loaded[k] = v; end
                end
                return loaded;
            end
        end
    end
    -- No settings file found — return a deep copy of the defaults
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
-- Module loading
-- Modules are loaded after globals are set up so they can
-- reference gSettings, gTracker, etc. at require-time.
------------------------------------------------------------
local nm_data  = require('nm_data');
local gui      = require('gui');
local tracker  = require('tracker');
local sounds   = require('sounds');
local importer = require('import');

------------------------------------------------------------
-- Globals
-- These are used by all modules for cross-module access.
------------------------------------------------------------
gSettings     = load_settings();
gZoning       = false;   -- true while the player is mid-zone-change
gZoneFrames   = 0;       -- frames counted since zone change began
gLastZone     = 0;
gPollFrame    = 0;       -- frame counter for entity polling throttle
gSaveSettings = save_settings;
gNmData       = nm_data;
gTracker      = tracker;
gSounds       = sounds;
gGui          = gui;

-- Load NM data for the player's current zone.
local function reload_zone_data()
    local zone = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
    nm_data:Load(zone);
end

------------------------------------------------------------
-- Command handlers
-- Each /eggs subcommand is its own function.
-- Guard clauses (early returns) keep nesting flat.
------------------------------------------------------------

local function cmd_help()
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
end

local function cmd_show()
    gSettings.tracker_visible = true;
    save_settings();
end

local function cmd_hide()
    gSettings.tracker_visible = false;
    save_settings();
end

local function cmd_settings()
    gSettings.settings_visible = not gSettings.settings_visible;
    save_settings();
end

local function cmd_browser()
    gSettings.nm_browser_visible = not gSettings.nm_browser_visible;
    if gSettings.nm_browser_visible then nm_data:LoadAllForBrowser(); end
    save_settings();
end

local function cmd_import()
    print(chat.header('Eggs') .. chat.message('Running import...'));
    importer:Run();
end

local function cmd_clear()
    gSettings.tracked    = {};
    gSettings.tod_data   = {};
    gTracker.ActiveTimers = T{};
    save_settings();
    print(chat.header('Eggs') .. chat.message('All timers cleared.'));
end

local function cmd_debug()
    gSettings.debug_mode = not gSettings.debug_mode;
    save_settings();
    print(chat.header('Eggs') .. chat.message(
        'Debug mode: ' .. (gSettings.debug_mode and 'ON' or 'OFF')));
    if not gSettings.debug_mode then return; end
    print(chat.header('Eggs') .. chat.message('Kill a PH mob to see its entity index, mob ID and sp_index.'));
    print(chat.header('Eggs') .. chat.message('Target a mob to see its PH lookup result.'));
    local mem_kb      = collectgarbage('count');
    local timer_count = 0; for _ in pairs(gTracker.ActiveTimers) do timer_count = timer_count + 1; end
    local track_count = 0; for _ in pairs(gSettings.tracked)      do track_count = track_count + 1; end
    local cache_count = 0;
    if gTracker and gTracker.LastStatus then
        for _ in pairs(gTracker.LastStatus) do cache_count = cache_count + 1; end
    end
    print(chat.header('Eggs') .. chat.message(string.format(
        'Lua heap: %.1f KB | Active timers: %d | Tracked NMs: %d | Entity cache: %d slots',
        mem_kb, timer_count, track_count, cache_count)));
end

-- /eggs deathtime <NM Name>
-- Shows the stored time of death for a tracked NM.
local function cmd_deathtime(args)
    local nm_name = table.concat(args, ' ', 2);
    if nm_name == '' then
        print(chat.header('Eggs') .. chat.message('Usage: /eggs deathtime <NM Name>'));
        return;
    end

    -- Build the key the same way RecordDeath does, then do a case-insensitive search
    local entry = nil;
    local search_key = ('nm:' .. nm_name:gsub('[^%w]', '_')):lower();
    if gSettings.tod_data then
        for k, v in pairs(gSettings.tod_data) do
            if k:lower() == search_key then
                entry = v;
                break;
            end
        end
    end

    if not entry then
        print(chat.header('Eggs') .. chat.message('No ToD recorded for: ' .. nm_name));
        return;
    end

    local t = os.date('*t', entry.tod_os);
    print(chat.header('Eggs') .. chat.message(string.format(
        '[%s] ToD: %02d/%02d/%04d %02d:%02d:%02d',
        nm_name, t.month, t.day, t.year, t.hour, t.min, t.sec)));
end

-- /eggs track <NM Name>
-- Adds an NM to the tracking list without requiring a ToD entry.
local function cmd_track(args)
    local nm_name = table.concat(args, ' ', 2);
    if nm_name == '' then
        print(chat.header('Eggs') .. chat.message('Usage: /eggs track <NM Name>'));
        return;
    end

    if not nm_data.AllNMsLoaded then nm_data:LoadAllForBrowser(); end

    local nm = nm_data:GetNMAnyZone(nm_name);
    if not nm then
        print(chat.header('Eggs') .. chat.error('NM not found: ' .. nm_name));
        return;
    end

    if nm.NMType == 'loot_only' then
        print(chat.header('Eggs') .. chat.error(nm.Name .. ' cannot be tracked (popped NM).'));
        return;
    end

    if not gSettings.tracked then gSettings.tracked = {}; end

    if gSettings.tracked[nm.Name] then
        print(chat.header('Eggs') .. chat.message('Already tracking: ' .. nm.Name));
        return;
    end

    gSettings.tracked[nm.Name] = { alarm = true };
    save_settings();
    print(chat.header('Eggs') .. chat.message('Now tracking: ' .. nm.Name));
end

-- /eggs loot <NM Name>
-- Opens the loot table window for an NM.
local function cmd_loot(args)
    local nm_name = table.concat(args, ' ', 2);
    if nm_name == '' then
        print(chat.header('Eggs') .. chat.message('Usage: /eggs loot <NM Name>'));
        return;
    end
    if not nm_data.AllNMsLoaded then nm_data:LoadAllForBrowser(); end
    gui:ShowLootWindow(nm_name);
end

-- /eggs fav <NM Name>
-- Toggles an NM in/out of the favorites list.
local function cmd_fav(args)
    local nm_name = table.concat(args, ' ');
    if nm_name == '' then return; end
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

-- /eggs tod [HH:MM:SS] [MM/DD/YYYY] <NM Name>
-- Records an NM death at a specific time (or now if no time given).
local function cmd_tod(args)
    -- Parse optional time and date arguments, then extract the NM name
    local time_str, date_str, name_start;

    -- Check arg 2 for a time string (HH:MM:SS or H:MM:SS AM/PM)
    local a2 = args[2] or '';
    if a2:match('^%d+:%d+:%d+$') then
        time_str   = a2;
        name_start = 3;
        -- Check arg 3 for AM/PM qualifier
        local a3 = args[3] or '';
        if a3:lower() == 'am' or a3:lower() == 'pm' then
            time_str   = time_str .. ' ' .. a3;
            name_start = 4;
        end
        -- Check next arg for a date string (MM/DD/YYYY)
        local an = args[name_start] or '';
        if an:match('^%d+/%d+/%d+$') then
            date_str   = an;
            name_start = name_start + 1;
        end
    else
        name_start = 2;
    end

    local nm_name = table.concat(args, ' ', name_start);
    if nm_name == '' then
        print(chat.header('Eggs') .. chat.message('Usage: /eggs tod [HH:MM:SS [MM/DD/YYYY]] <NM Name>'));
        return;
    end

    if not nm_data.AllNMsLoaded then nm_data:LoadAllForBrowser(); end
    local nm = nm_data:GetNMAnyZone(nm_name);
    if not nm then
        print(chat.header('Eggs') .. chat.error('NM not found: ' .. nm_name));
        return;
    end

    -- Parse the tod timestamp
    local tod_os = nil;
    if time_str then
        local h, m, s = time_str:match('^(%d+):(%d+):(%d+)');
        h, m, s = tonumber(h), tonumber(m), tonumber(s);
        local is_pm = time_str:lower():find('pm') ~= nil;
        local is_am = time_str:lower():find('am') ~= nil;
        if is_pm and h < 12 then h = h + 12; end
        if is_am and h == 12 then h = 0; end
        local t = os.date('*t');
        if date_str then
            local mo, dy, yr = date_str:match('^(%d+)/(%d+)/(%d+)');
            t.month, t.day, t.year = tonumber(mo), tonumber(dy), tonumber(yr);
        end
        t.hour, t.min, t.sec = h, m, s;
        tod_os = os.time(t);
        -- If the resulting time is in the future, assume yesterday
        if tod_os > os.time() then tod_os = tod_os - 86400; end
    end

    -- Determine window bounds based on NM type
    local window_min, window_max;
    if nm.NMType == 'timed_spawn' then
        window_min = nm.WindowMin or 0;
        window_max = nm.WindowMax or 0;
    else
        window_min = nm.Cooldown or 0;
        window_max = 0;
    end

    if window_min == 0 and window_max == 0 then
        if nm.NMType == 'timed_spawn' then
            print(chat.header('Eggs') .. chat.error(
                nm.Name .. ' has no window data. Try running /eggs import to regenerate data.'));
        else
            print(chat.header('Eggs') .. chat.message(
                nm.Name .. ' has no cooldown (True Lottery). PHs resume immediately — nothing to track.'));
        end
        return;
    end

    -- Remove any stale PH timers for this NM before recording the new death
    local to_del = {};
    for key, entry in pairs(gTracker.ActiveTimers) do
        if entry.nm_name == nm.Name and entry.type == 'ph' then
            to_del[#to_del + 1] = key;
        end
    end
    for _, k in ipairs(to_del) do gTracker:RemoveTimer(k); end

    local zone_id = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
    gTracker:RecordDeath('nm', nm.Name, nil, 0, zone_id, window_min, window_max, tod_os);
end

-- /eggs <NM Name> (fallback)
-- Opens the PH detail window for a named NM.
local function cmd_detail(args)
    local nm_name = table.concat(args, ' ');
    if nm_name == '' then return; end
    if not nm_data.AllNMsLoaded then nm_data:LoadAllForBrowser(); end
    gui:SetDetailTarget(nm_name);
    if gSettings.ph_detail_visible then save_settings(); end
end

------------------------------------------------------------
-- Command dispatch table
-- Maps subcommand strings to their handler functions.
-- Unknown commands fall through to cmd_detail (NM name lookup).
------------------------------------------------------------
local command_handlers = {
    help      = function(args) cmd_help(); end,
    show      = function(args) cmd_show(); end,
    hide      = function(args) cmd_hide(); end,
    settings  = function(args) cmd_settings(); end,
    browser   = function(args) cmd_browser(); end,
    import    = function(args) cmd_import(); end,
    clear     = function(args) cmd_clear(); end,
    debug     = function(args) cmd_debug(); end,
    deathtime = cmd_deathtime,
    track     = cmd_track,
    loot      = cmd_loot,
    fav       = cmd_fav,
    tod       = cmd_tod,
};

local function handle_command(args)
    local cmd = (args[1] or ''):lower();
    local handler = command_handlers[cmd];
    if handler then
        handler(args);
    else
        -- No matching command — treat the whole input as an NM name
        cmd_detail(args);
    end
end

------------------------------------------------------------
-- Ashita event hooks
------------------------------------------------------------

-- On load: initialize all modules and load NM data.
ashita.events.register('load', 'eggs_load', function()
    reload_zone_data();
    tracker:Initialize();
    sounds:Initialize();
    gui:Initialize();
    nm_data:LoadAllForBrowser();
    print(chat.header('Eggs') .. chat.message(
        string.format('v%s loaded. /eggs help for commands.', addon.version)));
end);

-- On unload: persist settings to disk.
ashita.events.register('unload', 'eggs_unload', function()
    save_settings();
end);

-- On command: route /eggs commands to the handler.
ashita.events.register('command', 'eggs_command', function(e)
    local args = e.command:args();
    if #args == 0 or args[1]:lower() ~= '/eggs' then return; end
    e.blocked = true;
    table.remove(args, 1);
    handle_command(args);
end);

-- Every frame: handle zoning detection, entity polling, and rendering.
ashita.events.register('d3d_present', 'eggs_present', function()
    -- Detect zoning by checking if the player entity name has cleared.
    -- The name goes blank the moment a zone transition begins.
    local em          = AshitaCore:GetMemoryManager():GetEntity();
    local player_name = em:GetName(0x400);
    local is_zoning   = (not player_name or player_name == '');

    if is_zoning and not gZoning then
        -- Zone transition just started — clear the entity cache immediately
        gZoning            = true;
        tracker.LastStatus = {};
    elseif not is_zoning and gZoning then
        -- Zone transition finished — wait 60 frames before resuming polling
        -- to avoid false death detections from entities flickering in
        gZoneFrames = (gZoneFrames or 0) + 1;
        if gZoneFrames >= 60 then
            gZoning            = false;
            gZoneFrames        = 0;
            tracker.LastStatus = {};
        end
    else
        gZoneFrames = 0;
    end

    -- Poll entities every 6 frames (~10/sec) while not zoning
    if not gZoning then
        gPollFrame = (gPollFrame or 0) + 1;
        if gPollFrame >= 6 then
            gPollFrame = 0;
            tracker:PollEntities();
        end
        -- Check for target changes
        local targetMgr = AshitaCore:GetMemoryManager():GetTarget();
        local targetIdx = targetMgr:GetTargetIndex(0);
        if targetIdx ~= gui.CurrentTarget then
            gui:HandleTargetChange(targetIdx);
        end
    end

    gui:Render();
end);

-- On zone change packet: reload NM data for the new zone.
ashita.events.register('packet_in', 'eggs_packet_in', function(e)
    if e.id ~= 0x00A then return; end
    local zone = struct.unpack('H', e.data, 0x30 + 1);
    if not zone or zone <= 0 then return; end
    nm_data:Load(zone);
    -- Reload the full browser list so cross-zone lookups stay current
    nm_data.AllNMsLoaded = false;
    nm_data:LoadAllForBrowser();
    -- Extend zone suppression window
    gZoning     = true;
    gZoneFrames = math.max(gZoneFrames, 300);
end);

-- On target change: notify the GUI so popups can update.
ashita.events.register('target_change', 'eggs_target_change', function(target_index)
    gui:HandleTargetChange(target_index);
end);
