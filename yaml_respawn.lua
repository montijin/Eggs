------------------------------------------------------------
-- yaml_respawn.lua
-- Resolves a mob's real respawn time from the server's own data:
--   core   data/zones/<zone>/mobs.yaml
--   module modules/<module>/data/.../zones/<zone>/mobs.yaml
-- Modules are read in init.txt order and win over the core file, the same
-- way the server merges them. Per spawn, a spawn-level respawn beats the
-- template's respawn.
--
-- This replaces guessing from old mob_groups.sql data or the 300s default,
-- so modules that change respawns (e.g. launch starter zones) are honored.
------------------------------------------------------------

local M = {};

local function lsb_root()
    return (gSettings and gSettings.lsb_server_path) or 'C:\\Phoenix-Workspace';
end

-- Launch starter zone module: extra mobs at offsets 824-1023 are respawned
-- by pxi_launch_names.lua right after the body fades, not by the wave.
-- 12s corpse + 3s fade = they are back 15s after dying.
local LAUNCH_ZONES = { [100] = true, [101] = true, [106] = true, [107] = true, [115] = true, [116] = true };
local LAUNCH_FIRST_OFFSET, LAUNCH_LAST_OFFSET = 824, 1023;
local LAUNCH_RESPAWN_SECS = 15;

M.Cache = {};   -- [zone_id] = { at = os.time(), core = parsed, mods = { parsed... }, has_launch = bool }
local zone_names;

local function read_lines(path)
    local f = io.open(path, 'r');
    if not f then return nil; end
    local lines = {};
    for line in f:lines() do lines[#lines + 1] = line; end
    f:close();
    return lines;
end

-- zone id -> folder name (east_ronfaure) from data/enums/zone.yaml
local function zone_name(zone_id)
    if not zone_names then
        zone_names = {};
        local lines = read_lines(lsb_root() .. '\\data\\enums\\zone.yaml');
        if lines then
            local in_values = false;
            for _, l in ipairs(lines) do
                if l:match('^values:') then
                    in_values = true;
                elseif in_values then
                    local name, id = l:match('^%s+([%w_]+):%s+(%d+)');
                    if name then zone_names[tonumber(id)] = name; end
                end
            end
        end
    end
    return zone_names[zone_id];
end

-- Minimal reader for the parts of mobs.yaml we need:
--   templates: <Name>: ... respawn: N
--   spawns:    <id>:      template: X ... respawn: N
local function parse(path)
    local lines = read_lines(path);
    if not lines then return nil; end

    local out = { templates = {}, spawns = {} };
    local section, cur_t, cur_s;

    for _, raw in ipairs(lines) do
        local l = raw:gsub('\r$', '');
        if not l:match('^%s*#') then
            l = l:gsub('%s+#.*$', '');
            if l:match('%S') then
                local indent = #l:match('^(%s*)');
                local body   = l:sub(indent + 1);

                if indent == 0 then
                    section, cur_t, cur_s = body:match('^([%w_]+):'), nil, nil;
                elseif section == 'templates' then
                    if indent == 2 then
                        local name = body:match('^([^%s:]+):%s*$');
                        cur_t = name and name:gsub('^["\'](.*)["\']$', '%1') or nil;
                    elseif cur_t then
                        local r = body:match('^respawn:%s*(%d+)%s*$');
                        if r and out.templates[cur_t] == nil then out.templates[cur_t] = tonumber(r); end
                    end
                elseif section == 'spawns' then
                    if indent == 2 then
                        local id = body:match('^(%d+):');
                        cur_s = id and tonumber(id) or nil;
                        if cur_s then out.spawns[cur_s] = {}; end
                    elseif cur_s then
                        local t = body:match('^template:%s*(%S+)');
                        if t and indent == 4 then out.spawns[cur_s].template = t; end
                        local r = body:match('^respawn:%s*(%d+)%s*$');
                        if r and out.spawns[cur_s].respawn == nil then out.spawns[cur_s].respawn = tonumber(r); end
                    end
                end
            end
        end
    end
    return out;
end

-- Data module roots from init.txt, in file order (later ones win), using the
-- same rule as the server: an entry containing 'data' is a data root, a bare
-- module name means <name>/data, anything else (lua/sql/cpp) is skipped.
local function module_roots()
    local lines = read_lines(lsb_root() .. '\\modules\\init.txt');
    local roots, seen, has_launch = {}, {}, false;
    for _, l in ipairs(lines or {}) do
        local e = l:gsub('\r', ''):gsub('^%s+', ''):gsub('%s+$', '');
        if e ~= '' and e:sub(1, 1) ~= '#' then
            e = e:gsub('/+$', '');
            local parts, explicit = {}, false;
            for p in e:gmatch('[^/]+') do
                parts[#parts + 1] = p;
                if p == 'data' then explicit = true; end
            end
            if explicit or #parts == 1 then
                local root = e .. (explicit and '' or '/data');
                if not seen[root] then
                    seen[root] = true;
                    roots[#roots + 1] = root;
                end
            end
            if e:find('launch_starter_zones', 1, true) then has_launch = true; end
        end
    end
    return roots, has_launch;
end

local function load_zone(zone_id)
    local c = M.Cache[zone_id];
    if c and (os.time() - c.at) < 60 then return c; end

    c = { at = os.time(), core = nil, mods = {}, has_launch = false };
    local name = zone_name(zone_id);
    if name then
        c.core = parse(lsb_root() .. '\\data\\zones\\' .. name .. '\\mobs.yaml');
        local roots, has_launch = module_roots();
        c.has_launch = has_launch;
        for _, root in ipairs(roots) do
            local p = parse(lsb_root() .. '\\modules\\' .. root:gsub('/', '\\')
                            .. '\\zones\\' .. name .. '\\mobs.yaml');
            if p then c.mods[#c.mods + 1] = p; end
        end
    end
    M.Cache[zone_id] = c;
    return c;
end

M.Clear = function() M.Cache = {}; zone_names = nil; end;

-- True for the launch module's extra mobs (respawned by script, not the wave).
M.IsScripted = function(zone_id, mob_id)
    if not (zone_id and mob_id and LAUNCH_ZONES[zone_id]) then return false; end
    local off = mob_id % 4096;
    if off < LAUNCH_FIRST_OFFSET or off > LAUNCH_LAST_OFFSET then return false; end

    -- Only mobs the module actually declares, in a zone where it is enabled.
    local c = load_zone(zone_id);
    if not c.has_launch then return false; end
    for _, p in ipairs(c.mods) do
        if p.spawns[mob_id] then return true; end
    end
    return false;
end;

------------------------------------------------------------
-- Resolve
-- Returns respawn_secs, source, scripted, from_module
--   respawn_secs nil when the data does not say
--   source       'launch' | 'spawn' | 'template'
--   scripted     true when the mob is respawned by script, not the wave
--   from_module  true when a module supplied the value
------------------------------------------------------------
M.Resolve = function(zone_id, mob_id)
    if not (zone_id and mob_id) then return nil; end

    if M.IsScripted(zone_id, mob_id) then
        return LAUNCH_RESPAWN_SECS, 'launch', true, true;
    end

    local c = load_zone(zone_id);
    if not c.core and #c.mods == 0 then return nil; end

    local function spawn_of(p) return p and p.spawns[mob_id]; end

    -- Spawn-level respawn: last module wins, then core.
    local s_r, s_from_mod = nil, false;
    for i = #c.mods, 1, -1 do
        local s = spawn_of(c.mods[i]);
        if s and s.respawn ~= nil then s_r, s_from_mod = s.respawn, true; break; end
    end
    local core_s = spawn_of(c.core);
    if s_r == nil and core_s and core_s.respawn ~= nil then s_r = core_s.respawn; end
    if s_r ~= nil then return s_r, 'spawn', false, s_from_mod; end

    -- Template: a module's spawn entry may name the template, else core's.
    local tmpl = core_s and core_s.template;
    for i = #c.mods, 1, -1 do
        local s = spawn_of(c.mods[i]);
        if s and s.template then tmpl = s.template; break; end
    end
    if not tmpl then return nil; end

    for i = #c.mods, 1, -1 do
        local r = c.mods[i].templates[tmpl];
        if r ~= nil then return r, 'template', false, true; end
    end
    local r = c.core and c.core.templates[tmpl];
    if r ~= nil then return r, 'template', false, false; end
    return nil;
end;

return M;
