------------------------------------------------------------
-- Eggs - NM Placeholder Tracker for Ashita v4
-- Author: Monti
-- Tracks placeholder mobs, respawn windows, and NM timers.
------------------------------------------------------------
addon.name    = 'Eggs';
addon.author  = 'Monti';
addon.desc    = 'NM Placeholder tracker and respawn timer';
addon.version = '1.01';

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
    print_window_time  = false,  -- print real-world window open time when a PH or NM death is recorded
    notify_default     = false,  -- automatically set a chat notify when recording a death
    notify_default_mins = 60,   -- how many minutes before eligibility to send the chat notify
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
-- tod_data is written last so it's easy to find and copy when sharing ToDs.
local function save_settings()
    local dir = string.format('%sconfig/addons/%s/', AshitaCore:GetInstallPath(), addon.name);
    ashita.fs.create_directory(dir);
    local f = io.open(SETTINGS_PATH, 'w');
    if not f then return; end

    -- Serialize everything except tod_data first
    local tod_data = gSettings.tod_data;
    gSettings.tod_data = nil;
    local main = serialize(gSettings);
    gSettings.tod_data = tod_data;

    -- Splice tod_data in as the last key before the closing brace
    local body = main:sub(1, -2); -- strip trailing '}'
    local tod_str = '    ["tod_data"] = ' .. serialize(tod_data or {}, 1);
    f:write('return ' .. body .. ',\n' .. tod_str .. '\n};\n');
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
    print(chat.header('Eggs') .. chat.message('/eggs clear <NM Name>  Clears the timer data for a specified NM'));
    print(chat.header('Eggs') .. chat.message('/eggs clear all        Clears all timer data for tracked NMs'));
    print(chat.header('Eggs') .. chat.message('/eggs debug           Toggle debug mode'));
    print(chat.header('Eggs') .. chat.message('/eggs <NM Name> deathtime  Show stored ToD for a tracked NM'));
    print(chat.header('Eggs') .. chat.message('/eggs track <NM Name>  Start tracking an NM'));
    print(chat.header('Eggs') .. chat.message('/eggs fav <NM Name>   Add/remove NM from favorites'));
    print(chat.header('Eggs') .. chat.message('/eggs loot <NM Name>  Show loot table for an NM'));
    print(chat.header('Eggs') .. chat.message('/eggs notify <NM Name> HH:MM or ##HR / ##min  Set chat notify before eligible'));
    print(chat.header('Eggs') .. chat.message('/eggs tod <NM Name> HH:MM:SS             Record NM death at time today'));
    print(chat.header('Eggs') .. chat.message('/eggs tod <NM Name> HH:MM:SS MM/DD/YYYY  Record NM death at specific date'));
    print(chat.header('Eggs') .. chat.message('/eggs <NM Name>       Open PH detail (works for any zone)'));
    print(chat.header('Eggs') .. chat.message('/eggs <NM Name> open  Show real-world clock time for next window'));
end

local function cmd_show()
    gSettings.tracker_visible = true;
    -- Reset the ImGui open flag so the window isn't immediately closed
    -- on the next frame after the user dismissed it with the X button.
    if gGui then gGui._tracker_open[1] = true; end
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

local function cmd_clear(args)
    local target = table.concat(args, ' ', 2):match('^%s*(.-)%s*$');
    if target == '' then
        print(chat.header('Eggs') .. chat.message(
            'Usage: /eggs clear <NM Name>  or  /eggs clear all'));
        return;
    end
    if target:lower() == 'all' then
        -- Trigger the shared confirm dialog in clear-all mode
        if gGui then gGui.ConfirmUntrack = '__all__'; end
    else
        -- Case-insensitive search through tracked NMs
        local matched = nil;
        local target_lower = target:lower();
        for nm_name in pairs(gSettings.tracked or {}) do
            if nm_name:lower() == target_lower then
                matched = nm_name;
                break;
            end
        end
        if not matched then
            print(chat.header('Eggs') .. chat.error('Not currently tracking: ' .. target));
            return;
        end
        if gGui then gGui.ConfirmUntrack = matched; end
    end
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

-- /eggs <NM Name> deathtime
-- Shows the stored time of death for a tracked NM.
-- Dispatch guarantees "deathtime" is the last word, so strip it with a range concat.
local function cmd_deathtime(args)
    local nm_name = table.concat(args, ' ', 1, #args - 1);
    if nm_name == '' then
        print(chat.header('Eggs') .. chat.message('Usage: /eggs <NM Name> deathtime'));
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
    local nm_name = table.concat(args, ' ', 2);
    if nm_name == '' then
        print(chat.header('Eggs') .. chat.message('Usage: /eggs fav <NM Name>'));
        return;
    end
    if not nm_data.AllNMsLoaded then nm_data:LoadAllForBrowser(); end
    local nm = nm_data:GetNMAnyZone(nm_name);
    if not nm then
        print(chat.header('Eggs') .. chat.error('NM not found: ' .. nm_name));
        return;
    end
    if not gSettings.favorites then gSettings.favorites = {}; end
    if gSettings.favorites[nm.Name] then
        gSettings.favorites[nm.Name] = nil;
        print(chat.header('Eggs') .. chat.message('Removed from favorites: ' .. nm.Name));
    else
        gSettings.favorites[nm.Name] = true;
        print(chat.header('Eggs') .. chat.message('Added to favorites: ' .. nm.Name));
    end
    save_settings();
end

-- /eggs notify <NM Name> HH:MM | #hr | #hr#min | #min
-- Sets a one-time chat notification before a tracked NM is eligible.
-- Accepts: 1:30 (HH:MM), 1hr, 1hr30min, 30min (case insensitive)
local function cmd_notify(args)
    local time_arg = (args[#args] or ''):lower();

    -- Try each supported time format in order of specificity.
    -- Each pattern captures hours and/or minutes and converts to seconds.
    local function parse_time(s)
        local hh, mm = s:match('^(%d+):(%d+)$');
        if hh then return tonumber(hh) * 3600 + tonumber(mm) * 60; end
        local hr, mn = s:match('^(%d+)hr(%d+)min$');
        if hr then return tonumber(hr) * 3600 + tonumber(mn) * 60; end
        local h = s:match('^(%d+)hr$');
        if h  then return tonumber(h) * 3600; end
        local m = s:match('^(%d+)min$');
        if m  then return tonumber(m) * 60; end
        return nil;
    end

    local notify_secs = parse_time(time_arg);
    if not notify_secs then
        print(chat.header('Eggs') .. chat.message(
            'Usage: /eggs notify <NM Name> HH:MM or ##HR / ##min'));
        return;
    end

    -- NM name is args[2..#args-1]
    local nm_name = table.concat(args, ' ', 2, #args - 1);
    if nm_name == '' then
        print(chat.header('Eggs') .. chat.message(
            'Usage: /eggs notify <NM Name> HH:MM or ##HR / ##min'));
        return;
    end

    -- Find the NM's active timer
    local nm_lower = nm_name:lower();
    local found_key, found_entry;
    for key, entry in pairs(gTracker.ActiveTimers) do
        if entry.type == 'nm' and entry.nm_name:lower() == nm_lower then
            found_key   = key;
            found_entry = entry;
            break;
        end
    end

    if not found_entry then
        print(chat.header('Eggs') .. chat.error(
            'No active timer for: ' .. nm_name .. '. Record a ToD first.'));
        return;
    end

    found_entry.notify_secs  = notify_secs;
    found_entry.notify_fired = false;
    if gSettings.tod_data[found_key] then
        gSettings.tod_data[found_key].notify_secs  = notify_secs;
        gSettings.tod_data[found_key].notify_fired = false;
    end
    save_settings();

    local h = math.floor(notify_secs / 3600);
    local m = math.floor((notify_secs % 3600) / 60);
    local time_label = h > 0 and (m > 0 and string.format('%dhr %dmin', h, m)
                                           or string.format('%dhr', h))
                               or string.format('%dmin', m);
    print(chat.header('Eggs') .. chat.message(string.format(
        '[%s] Notify set: %s before eligible.', found_entry.nm_name, time_label)));
end
-- /eggs tod <NM Name> [HH:MM:SS] [MM/DD/YYYY]
-- Records an NM death at a specific time (or now if no time given).
-- NM name comes immediately after "tod"; optional time and date follow the name.
local function cmd_tod(args)
    -- Strip the leading "tod" subcommand word, then parse from the end:
    -- last arg may be MM/DD/YYYY (date), second-to-last may be HH:MM:SS (time).
    -- Everything before those optional suffixes is the NM name.
    local time_str, date_str;
    local name_end = #args; -- inclusive index of last NM name word

    local last = args[name_end] or '';
    if last:match('^%d+/%d+/%d+$') then
        date_str = last;
        name_end = name_end - 1;
        last = args[name_end] or '';
    end

    if last:match('^%d+:%d+:%d+$') then
        time_str = last;
        name_end = name_end - 1;
        -- Check for AM/PM qualifier immediately after time (shouldn't happen with new
        -- syntax but kept for robustness)
    end

    -- args[2..name_end] is the NM name (args[1] == 'tod')
    local nm_name = table.concat(args, ' ', 2, name_end);
    if nm_name == '' then
        print(chat.header('Eggs') .. chat.message(
            'Usage: /eggs tod <NM Name> [HH:MM:SS] [MM/DD/YYYY]'));
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

    -- Auto-track the NM if it isn't already — /eggs tod implies the player wants it watched.
    if not gSettings.tracked then gSettings.tracked = {}; end
    if not gSettings.tracked[nm.Name] then
        gSettings.tracked[nm.Name] = { alarm = true };
        print(chat.header('Eggs') .. chat.message('Now tracking: ' .. nm.Name));
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

-- /eggs <NM Name> open
-- Prints the real-world clock time when this NM's window opens.
-- Requires an active timer (ToD must be recorded).
local function cmd_open(args)
    -- Strip the trailing 'open' keyword to get the NM name
    local nm_name = table.concat(args, ' ', 1, #args - 1);
    if nm_name == '' then
        print(chat.header('Eggs') .. chat.message('Usage: /eggs <NM Name> open'));
        return;
    end

    if not nm_data.AllNMsLoaded then nm_data:LoadAllForBrowser(); end
    local nm = nm_data:GetNMAnyZone(nm_name);
    if not nm then
        print(chat.header('Eggs') .. chat.error('NM not found: ' .. nm_name));
        return;
    end

    -- Find the active NM timer
    local safe      = nm.Name:gsub('[^%w]', '_');
    local nm_key    = 'nm:' .. safe;
    local nm_timer  = gTracker.ActiveTimers[nm_key];

    if not nm_timer then
        print(chat.header('Eggs') .. chat.message(
            '[' .. nm.Name .. '] No active timer. Record a ToD first with /eggs tod.'));
        return;
    end

    local open_at  = nm_timer.tod_os + nm_timer.respawn_secs;
    local close_at = nm_timer.window_secs > 0 and (nm_timer.tod_os + nm_timer.window_secs) or nil;
    local today    = os.date('%Y%m%d', os.time());
    local wcount   = nm and nm.WindowCount or 0;

    local function fmt_clock(t)
        if os.date('%Y%m%d', t) == today then
            return os.date('%I:%M:%S %p', t);
        end
        return os.date('%a %I:%M:%S %p', t);
    end

    if wcount > 1 then
        local close_str = close_at and fmt_clock(close_at) or '?';
        print(chat.header('Eggs') .. chat.message(string.format(
            '[%s] Window: %s - %s  (%d windows)',
            nm.Name, fmt_clock(open_at), close_str, wcount)));
    elseif close_at then
        print(chat.header('Eggs') .. chat.message(string.format(
            '[%s] Opens: %s  Closes: %s', nm.Name, fmt_clock(open_at), fmt_clock(close_at))));
    else
        print(chat.header('Eggs') .. chat.message(string.format(
            '[%s] Eligible at: %s', nm.Name, fmt_clock(open_at))));
    end
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
    clear     = function(args) cmd_clear(args); end,
    debug     = function(args) cmd_debug(); end,
    track     = cmd_track,
    loot      = cmd_loot,
    fav       = cmd_fav,
    notify    = cmd_notify,
    tod       = cmd_tod,
};

local function handle_command(args)
    local cmd = (args[1] or ''):lower();
    local handler = command_handlers[cmd];
    if handler then
        handler(args);
        return;
    end
    -- Check if the last word is 'open' or 'deathtime' — e.g. /eggs Tiamat open
    if args[#args] and #args > 1 then
        local last = args[#args]:lower();
        if last == 'open' then
            cmd_open(args);
            return;
        end
        if last == 'deathtime' then
            cmd_deathtime(args);
            return;
        end
    end
    -- No matching command — treat the whole input as an NM name
    cmd_detail(args);
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
