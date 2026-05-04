require('common');
local chat = require('chat');
------------------------------------------------------------
-- import.lua  (Eggs v1.0 - by Monti)
-- Parses LSB server scripts + SQL to build per-zone NM data.
--
-- NM Types:
--   Timed Lottery -> phOnDespawn with cooldown > 0
--   True Lottery  -> phOnDespawn with cooldown == 0
--   Timed Spawn   -> setRespawnTime, no placeholder
--
-- Usage: /eggs import
------------------------------------------------------------

local import_module = {};

-- *** SET THIS TO YOUR LSB\server FOLDER ***
local LSB_SERVER = 'C:\\LSB\\server';

-- Derived paths (no need to edit below)
local ZONES_PATH = LSB_SERVER .. '\\scripts\\zones';
local SQL_PATH   = LSB_SERVER .. '\\sql';
local OUTPUTPATH = string.format('%sdata', addon.path);
local ERRORPATH  = string.format('%serrors.txt', addon.path);

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local function popen_lines(cmd)
    local result = {};
    local pipe = io.popen(cmd .. ' 2>nul');
    if not pipe then return result; end
    for line in pipe:lines() do
        local t = line:match('^%s*(.-)%s*$');
        if t and t ~= '' then result[#result + 1] = t; end
    end
    pipe:close();
    return result;
end

local function list_subdirs(path)
    return popen_lines('dir /b /ad "' .. path .. '"');
end

local function list_lua_files(path)
    return popen_lines('dir /b "' .. path .. '\\*.lua"');
end

local function read_file(path)
    local f = io.open(path, 'r');
    if not f then return nil; end
    local c = f:read('*all');
    f:close();
    return c;
end

------------------------------------------------------------
-- Step 1a: Parse mob_spawn_points.sql
-- Builds: SpawnById[mob_id] = {Name, RawName, ZoneId, Index, GroupId}
------------------------------------------------------------
import_module.ParseSpawnPoints = function(self)
    self.SpawnById   = {};
    self.SpawnByZone = {};

    local path = SQL_PATH .. '\\mob_spawn_points.sql';
    local f = io.open(path, 'r');
    if not f then
        print(chat.header('Eggs') .. chat.error('Cannot open: ' .. path));
        print(chat.header('Eggs') .. chat.error('Check LSB_SERVER path in import.lua'));
        return false;
    end

    local count = 0;
    for line in f:lines() do
        if line:find('INSERT INTO') then
            -- (mob_id, groupid, internal_name, display_name, ...)
            local mob_id, group_id, iname, dname = line:match(
                "VALUES%s*%(%s*(%d+)%s*,%s*(%d+)%s*,%s*'([^']+)'%s*,%s*'([^']+)'");
            if mob_id then
                mob_id   = tonumber(mob_id);
                group_id = tonumber(group_id);
                local zone_id = math.floor(mob_id / 4096) % 512;
                local index   = mob_id % 1024;
                local entry = {
                    Name    = dname:gsub('_', ' '),
                    RawName = iname,
                    ZoneId  = zone_id,
                    Index   = index,
                    Id      = mob_id,
                    GroupId = group_id,
                };
                self.SpawnById[mob_id] = entry;
                if not self.SpawnByZone[zone_id] then
                    self.SpawnByZone[zone_id] = {};
                end
                self.SpawnByZone[zone_id][mob_id] = entry;
                count = count + 1;
            end
        end
    end
    f:close();
    print(chat.header('Eggs') .. chat.message('Parsed ' .. count .. ' spawn points.'));
    return true;
end;

------------------------------------------------------------
-- Step 1c: Parse mob_droplist.sql
-- Builds: Drops[zone_id][nm_name_lower] = { {Name, Rate, Type}, ... }
-- dropType: 0=normal, 1=group, 2=steal, 4=despoil
-- Rate is out of 1000 (1000=100%, 500=50%, etc.)
------------------------------------------------------------
import_module.ParseDroplist = function(self)
    self.Drops = {};

    local path = SQL_PATH .. '\\mob_droplist.sql';
    local f = io.open(path, 'r');
    if not f then
        print(chat.header('Eggs') .. chat.message('No mob_droplist.sql found - skipping loot data.'));
        return true;  -- non-fatal
    end

    -- Variable substitutions
    local vars = {
        ['@ALWAYS']  = 1000,
        ['@VCOMMON'] = 240,
        ['@COMMON']  = 150,
        ['@UNCOMMON']= 100,
        ['@RARE']    = 50,
        ['@VRARE']   = 10,
        ['@SRARE']   = 5,
        ['@URARE']   = 1,
    };

    local current_zone = nil;
    local current_nm   = nil;
    local count        = 0;

    for line in f:lines() do
        -- Check for zone/NM comment: -- ZoneID: 107 - Leaping Lizzy
        local zone_id, nm_name = line:match('^%s*%-%-%s*ZoneID:%s*(%d+)%s*%-%s*(.+)$');
        if zone_id then
            -- Strip trailing comments/spaces from nm_name
            nm_name = nm_name:match('^(.-)%s*%-%-.*$') or nm_name;
            nm_name = nm_name:match('^(.-)%s*$');
            current_zone = tonumber(zone_id);
            current_nm   = nm_name:lower();
            if not self.Drops[current_zone] then
                self.Drops[current_zone] = {};
            end
            if not self.Drops[current_zone][current_nm] then
                self.Drops[current_zone][current_nm] = {};
            end
        elseif line:find('INSERT INTO') and current_zone and current_nm then
            -- Parse: VALUES (dropId, dropType, groupId, groupRate, itemId, itemRate)
            -- Item name is in trailing comment: -- Item Name (...)
            local drop_type, group_id, group_rate_raw, item_rate_raw = line:match(
                "VALUES%s*%(%d+,%s*(%d+),%s*(%d+),%s*([^,]+),%s*%d+,%s*([^%)]+)%s*%)");
            local item_name = line:match('%-%-%s*([^%(]+)%s*%(') or
                              line:match('%-%-%s*(.+)$');
            if item_name then
                item_name = item_name:match('^%s*(.-)%s*$');
            end

            if drop_type and item_rate_raw and item_name then
                drop_type        = tonumber(drop_type);
                group_rate_raw   = group_rate_raw:match('^%s*(.-)%s*$');
                item_rate_raw    = item_rate_raw:match('^%s*(.-)%s*$');
                local group_rate = vars[group_rate_raw] or tonumber(group_rate_raw) or 1000;
                local item_rate  = vars[item_rate_raw]  or tonumber(item_rate_raw)  or 0;

                -- Effective rate:
                -- type 0 = normal drop: rate is item_rate directly (groupRate is always 1000)
                -- type 1 = group drop: effective = groupRate * itemRate / 1000
                -- type 2 = steal, type 4 = despoil: rate is item_rate directly
                local effective_rate;
                if drop_type == 1 then
                    effective_rate = math.floor(group_rate * item_rate / 1000);
                else
                    effective_rate = item_rate;
                end

                if drop_type == 0 or drop_type == 1 or drop_type == 2 or drop_type == 4 then
                    local drops = self.Drops[current_zone][current_nm];
                    drops[#drops + 1] = {
                        Name      = item_name,
                        Rate      = effective_rate,
                        Type      = drop_type,
                        GroupId   = tonumber(group_id) or 0,
                        GroupRate = group_rate,
                    };
                    count = count + 1;
                end
            end
        end
    end

    f:close();
    print(chat.header('Eggs') .. chat.message('Parsed ' .. count .. ' drop entries.'));
    return true;
end;
-- Builds: Groups[zone_id][group_id] = { RespawnTime, PoolId }
------------------------------------------------------------
import_module.ParseGroups = function(self)
    self.Groups = {};

    local path = SQL_PATH .. '\\mob_groups.sql';
    local f = io.open(path, 'r');
    if not f then
        print(chat.header('Eggs') .. chat.error('Cannot open: ' .. path));
        return false;
    end

    local count = 0;
    for line in f:lines() do
        -- Strip comments
        local comment = line:find('%-%-');
        if comment then line = line:sub(1, comment - 1); end
        if line:find('INSERT INTO') then
            local start_p = line:find('%(');
            local end_p   = line:find('%)');
            if start_p and end_p then
                local sub   = line:sub(start_p + 1, end_p - 1);
                local parts = {};
                for v in sub:gmatch('([^,]+)') do
                    parts[#parts + 1] = v:match('^%s*(.-)%s*$');
                end
                -- mob_groups columns:
                -- 1=groupid, 2=poolid, 3=zone, 4=text_id, 5=respawnTime, ...
                local group_id    = tonumber(parts[1]);
                local pool_id     = tonumber(parts[2]);
                local zone_id     = tonumber(parts[3]);
                local respawn     = tonumber(parts[5]);
                if group_id and zone_id and respawn then
                    if not self.Groups[zone_id] then
                        self.Groups[zone_id] = {};
                    end
                    self.Groups[zone_id][group_id] = {
                        RespawnTime = respawn,
                        PoolId      = pool_id,
                    };
                    count = count + 1;
                end
            end
        end
    end
    f:close();
    print(chat.header('Eggs') .. chat.message('Parsed ' .. count .. ' mob groups.'));
    return true;
end;

------------------------------------------------------------
-- Get respawn time for a mob_id from mob_groups
------------------------------------------------------------
import_module.GetRespawnTime = function(self, mob_id, zone_id)
    local spawn = self.SpawnById[mob_id];
    if not spawn then return 300; end
    local zone_groups = self.Groups[zone_id];
    if not zone_groups then return 300; end
    local group = zone_groups[spawn.GroupId];
    return group and group.RespawnTime or 300;
end;

------------------------------------------------------------
-- Step 2: Parse a zone's IDs.lua for mob key -> mob_id
------------------------------------------------------------
import_module.ParseZoneIDs = function(self, zone_path, zone_id)
    local content = read_file(zone_path .. '\\IDs.lua');
    if not content then return {}; end
    local mob_ids = {};
    -- Standard scalar keys: CARNERO = GetFirstID(...) -> single number literal
    for key, val in content:gmatch('%.mob%.([%w_]+)%s*=%s*(%d+)') do
        mob_ids[key] = tonumber(val);
    end
    -- Array-indexed literal keys: LEAPING_LIZZY[1] = 17215868
    for key, idx, val in content:gmatch('%.mob%.([%w_]+)%[(%d+)%]%s*=%s*(%d+)') do
        mob_ids[key .. '[' .. idx .. ']'] = tonumber(val);
    end
    -- GetTableOfIDs keys: LEAPING_LIZZY = GetTableOfIDs('Leaping_Lizzy')
    -- No literal IDs in IDs.lua — resolve from SQL spawn data in sorted order
    if zone_id and self.SpawnByZone[zone_id] then
        for key, raw_name in content:gmatch("%.mob%.([%w_]+)%s*=%s*GetTableOfIDs%s*%(%s*'([^']+)'%s*%)") do
            local matches = {};
            for mid, sp in pairs(self.SpawnByZone[zone_id]) do
                if sp.RawName == raw_name then
                    matches[#matches + 1] = mid;
                end
            end
            table.sort(matches);
            for i, mid in ipairs(matches) do
                mob_ids[key .. '[' .. i .. ']'] = mid;
            end
        end
    end
    return mob_ids;
end;

------------------------------------------------------------
-- Parse phList expression: "ID.mob.KEY +/- N"
------------------------------------------------------------
local function parse_ph_expr(expr)
    expr = expr:match('^%s*(.-)%s*$');
    -- Array-indexed with offset: ID.mob.LEAPING_LIZZY[1] - 1
    local key, idx, op, n = expr:match('ID%.mob%.([%w_]+)%[(%d+)%]%s*([%+%-])%s*(%d+)');
    if key then
        local off = tonumber(n) or 0;
        return key .. '[' .. idx .. ']', (op == '-') and -off or off;
    end
    -- Array-indexed no offset: ID.mob.LEAPING_LIZZY[1]
    local key_arr, idx_arr = expr:match('^ID%.mob%.([%w_]+)%[(%d+)%]$');
    if key_arr then return key_arr .. '[' .. idx_arr .. ']', 0; end
    -- Standard with offset: ID.mob.CARNERO + 11
    local key2, op2, n2 = expr:match('ID%.mob%.([%w_]+)%s*([%+%-])%s*(%d+)');
    if key2 then
        local off = tonumber(n2) or 0;
        return key2, (op2 == '-') and -off or off;
    end
    -- Standard no offset: ID.mob.CARNERO
    local key3 = expr:match('^ID%.mob%.([%w_]+)$');
    if key3 then return key3, 0; end
    return nil, nil;
end;

------------------------------------------------------------
-- Parse phOnDespawn call from a PH mob file
-- Returns a list of all phOnDespawn entries found (a PH file can spawn multiple NMs)
------------------------------------------------------------
local function parse_ph_despawn(content)
    local results = {};
    -- Pattern 1: fixed cooldown  phOnDespawn(mob, ID.mob.X, chance, cooldown)
    for nm_ref, chance, cooldown in content:gmatch(
        'xi%.mob%.phOnDespawn%s*%(%s*mob%s*,%s*(ID%.mob%.[%w_%[%]]+)%s*,%s*(%d+)%s*,%s*(%d+)') do
        local raw_key  = nm_ref:match('ID%.mob%.(.+)$');
        local bare_key = raw_key:match('^([%w_]+)%[') or raw_key;
        results[#results + 1] = {
            nm_key      = raw_key,
            nm_bare_key = bare_key,
            chance      = tonumber(chance)   or 0,
            cooldown    = tonumber(cooldown) or 0,
            ph_type     = 'standard',
        };
    end
    -- Pattern 2: math.random cooldown  phOnDespawn(mob, ID.mob.X, chance, math.random(min, max))
    for nm_ref, chance, cd_min, cd_max in content:gmatch(
        'xi%.mob%.phOnDespawn%s*%(%s*mob%s*,%s*(ID%.mob%.[%w_%[%]]+)%s*,%s*(%d+)%s*,%s*math%.random%s*%(%s*(%d+)%s*,%s*(%d+)%s*%)') do
        local raw_key  = nm_ref:match('ID%.mob%.(.+)$');
        local bare_key = raw_key:match('^([%w_]+)%[') or raw_key;
        -- Use the max of the range as cooldown (worst case for the player)
        results[#results + 1] = {
            nm_key      = raw_key,
            nm_bare_key = bare_key,
            chance      = tonumber(chance) or 0,
            cooldown    = tonumber(cd_max) or 0,
            ph_type     = 'standard',
        };
    end
    return #results > 0 and results or nil;
end;

------------------------------------------------------------
-- Detect timed spawn window from NM file
------------------------------------------------------------
-- Parse respawn time set on PH mobs by NM file (e.g. King Arthro sets Knight Crab timers)
-- Returns min, max in seconds, or nil if not found
local function parse_ph_respawn_from_nm(content)
    -- Pattern: setRespawnTime called inside a loop over getID() - offset
    -- e.g. GetMobByID(mob:getID() - offset):setRespawnTime(75900 + math.random(0,6)*1800)
    -- Case A: fixed + random offset  e.g. 75900 + math.random(0, 6) * 1800
    local base_s, rand_max_s, mult_s = content:match(
        'getID%(%s*%)%s*%-%s*offset%)%s*:setRespawnTime%s*%(%s*(%d+)%s*%+%s*math%.random%s*%(%s*%d+%s*,%s*(%d+)%s*%)%s*%*%s*(%d+)');
    if base_s then
        local base = tonumber(base_s);
        local rmax = tonumber(rand_max_s) * tonumber(mult_s);
        return base, base + rmax;
    end
    -- Case B: plain fixed  e.g. setRespawnTime(respawnTime) where respawnTime = a + math.random(0,n)*m
    local rv_base, rv_rmax, rv_mult = content:match(
        'respawnTime%s*=%s*(%d+)%s*%+%s*math%.random%s*%(%s*%d+%s*,%s*(%d+)%s*%)%s*%*%s*(%d+)');
    -- Check if this respawnTime is used in getID() - offset context
    if rv_base and content:find('getID.*offset.*setRespawnTime.*respawnTime') or
       rv_base and content:find('setRespawnTime%s*%(respawnTime%)') then
        local base = tonumber(rv_base);
        local rmax = tonumber(rv_rmax) * tonumber(rv_mult);
        return base, base + rmax;
    end
    return nil, nil;
end;

local function parse_timed_spawn(content)
    -- Special case: NM sets respawn on PH mobs via getID() - offset
    -- e.g. King Arthro: respawnTime = 900 + math.random(0, 6) * 1800
    local ka_base, ka_rmax, ka_mult = content:match(
        'respawnTime%s*=%s*(%d+)%s*%+%s*math%.random%s*%(%s*%d+%s*,%s*(%d+)%s*%)%s*%*%s*(%d+)');
    if ka_base and content:find('getID%(%s*%)%s*%-%s*offset') then
        local base = tonumber(ka_base);
        local n    = tonumber(ka_rmax);
        local mult = tonumber(ka_mult);
        local rmax = base + n * mult;
        -- Use the onMobDespawn respawn (the real post-death timer), not onMobInitialize
        local all_bases = {};
        for b in content:gmatch('respawnTime%s*=%s*(%d+)%s*%+') do
            all_bases[#all_bases+1] = tonumber(b);
        end
        table.sort(all_bases);
        local real_base = all_bases[#all_bases] or base;
        local rb_max, rb_mult = content:match(
            tostring(real_base) .. '%s*%+%s*math%.random%s*%(%s*%d+%s*,%s*(%d+)%s*%)%s*%*%s*(%d+)');
        if rb_max then
            local real_n    = tonumber(rb_max);
            local real_mult = tonumber(rb_mult);
            return real_base, real_base + real_n * real_mult, real_mult, real_n + 1;
        end
        return real_base, real_base, 0, 1;
    end

    -- Case 1: setRespawnTime(math.random(a, b) * m)  e.g. Tiamat: math.random(144,240)*1800
    local rmin_s, rmax_s, mult_s = content:match(
        'setRespawnTime%s*%(%s*math%.random%s*%(%s*(%d+)%s*,%s*(%d+)%s*%)%s*%*%s*(%d+)');
    if rmin_s then
        local mult  = tonumber(mult_s) or 1;
        local rmin  = tonumber(rmin_s);
        local rmax  = tonumber(rmax_s);
        local count = rmax - rmin + 1;
        return rmin * mult, rmax * mult, mult, count;
    end
    -- Case 2: setRespawnTime(math.random(a, b))  plain random, no fixed interval
    rmin_s, rmax_s = content:match(
        'setRespawnTime%s*%(%s*math%.random%s*%(%s*(%d+)%s*,%s*(%d+)%s*%)%s*%)');
    if rmin_s then return tonumber(rmin_s), tonumber(rmax_s), 0, 0; end
    -- Case 2b: GetSystemTime() + math.random(a, b)  e.g. Heliodromos zone variable timer
    rmin_s, rmax_s = content:match(
        'GetSystemTime%s*%(%s*%)%s*%+%s*math%.random%s*%(%s*(%d+)%s*,%s*(%d+)%s*%)');
    if rmin_s then return tonumber(rmin_s), tonumber(rmax_s), 0, 0; end
    -- Case 3: setRespawnTime(a * m)  fixed with multiplier
    local a_s, b_s = content:match('setRespawnTime%s*%(%s*(%d+)%s*%*%s*(%d+)%s*%)');
    if a_s then local v = tonumber(a_s) * tonumber(b_s); return v, v, 0, 1; end
    -- Case 4: setRespawnTime(n)  plain fixed
    local fixed = content:match('setRespawnTime%s*%(%s*(%d+)%s*%)');
    if fixed then local v = tonumber(fixed); return v, v, 0, 1; end
    return nil, nil, 0, 0;
end;

local function is_nm_file(content)
    return content:find('entity%.phList') or
           content:find('entity%.spawnPoints') or
           content:find('setRespawnTime') or
           content:find("require%('scripts/mixins/rage'%)") or
           content:find("require%('scripts/mixins/draw_in'%)") or
           content:find('xi%.mob%.updateNMSpawnPoint');
end;

------------------------------------------------------------
-- Resolve PH mob IDs from phList block
------------------------------------------------------------
local function resolve_ph_ids(content, mob_ids, nm_key, nm_mob_id, spawn_by_id)
    local ph_block = content:match('entity%.phList%s*=%s*(%b{})');
    if not ph_block then return {}; end

    -- Pre-build a sorted list of all IDs sharing the NM's RawName in the same zone
    -- Used to resolve LEAPING_LIZZY[2] etc. when mob_ids doesn't have them
    local nm_spawn = nm_mob_id and spawn_by_id[nm_mob_id];
    local nm_raw   = nm_spawn and nm_spawn.RawName;
    local nm_zone  = nm_spawn and nm_spawn.ZoneId;
    local nm_siblings = {};  -- sorted list of IDs with same RawName in same zone
    if nm_raw and nm_zone then
        for mid, sp in pairs(spawn_by_id) do
            if sp.RawName == nm_raw and sp.ZoneId == nm_zone then
                nm_siblings[#nm_siblings + 1] = mid;
            end
        end
        table.sort(nm_siblings);
    end

    local phs = {};
    local seen = {};

    -- Match phList keys: handles both plain [ID.mob.KEY +/- N] and
    -- nested-bracket [ID.mob.KEY[N] +/- N] by grabbing up to the last ]
    -- before the = sign on each line
    for ph_expr in ph_block:gmatch('%[([^=\n]+)%]%s*=') do
        ph_expr = ph_expr:match('^%s*(.-)%s*$');
        local ph_key, ph_offset = parse_ph_expr(ph_expr);
        if ph_key then
            local base_id;
            if ph_key == nm_key and nm_mob_id then
                base_id = nm_mob_id;
            else
                base_id = mob_ids[ph_key];
                -- Fallback for array-indexed keys not in mob_ids (e.g. LEAPING_LIZZY[2]
                -- when IDs.lua uses GetTableOfIDs and only [1] was referenced by PH files)
                if not base_id then
                    local bare, idx = ph_key:match('^([%w_]+)%[(%d+)%]$');
                    if bare and idx and #nm_siblings > 0 then
                        -- Bare key must match the NM's own bare key
                        local nm_bare = nm_key:match('^([%w_]+)%[') or nm_key;
                        if bare == nm_bare then
                            base_id = nm_siblings[tonumber(idx)];
                        end
                    end
                end
            end
            if base_id then
                local ph_mob_id = base_id + ph_offset;
                if not seen[ph_mob_id] then
                    seen[ph_mob_id] = true;
                    local spawn = spawn_by_id[ph_mob_id];
                    phs[#phs + 1] = {
                        Id    = ph_mob_id,
                        Index = spawn and spawn.Index or (ph_mob_id % 1024),
                        Name  = spawn and spawn.Name  or ('Mob #' .. ph_mob_id),
                    };
                end
            end
        end
    end
    return phs;
end;

------------------------------------------------------------
-- Process one zone folder
------------------------------------------------------------
import_module.ProcessZone = function(self, zone_id, zone_name, zone_path, mob_ids)
    local mobs_path = zone_path .. '\\mobs';
    local files = list_lua_files(mobs_path);
    if #files == 0 then return {}; end

    local nms         = {};
    local nm_files    = {};
    local ph_spawners = {};

    for _, fname in ipairs(files) do
        local raw_key = fname:match('^(.-)%.lua$') or fname;
        if nm_files[raw_key] then goto next_file; end

        local fpath   = mobs_path .. '\\' .. fname;
        local content = read_file(fpath);
        if not content then goto next_file; end

        local mob_name = raw_key:gsub('_', ' ');
        local ph_infos = parse_ph_despawn(content);

        if ph_infos then
            for _, ph_info in ipairs(ph_infos) do
                ph_spawners[#ph_spawners + 1] = {
                    content     = content,
                    raw_key     = raw_key,
                    mob_name    = mob_name,
                    nm_key      = ph_info.nm_key,
                    nm_bare_key = ph_info.nm_bare_key,
                    chance      = ph_info.chance,
                    cooldown    = ph_info.cooldown,
                };
            end
        elseif is_nm_file(content) then
            nm_files[raw_key] = { content = content, mob_name = mob_name };
        end

        ::next_file::
    end

    local function find_nm(key)
        if nm_files[key] then return nm_files[key], key; end
        local pretty = key:gsub('_', ' ');
        if nm_files[pretty] then return nm_files[pretty], pretty; end
        for k, v in pairs(nm_files) do
            if k:lower() == key:lower() then return v, k; end
        end
        return nil, nil;
    end;

    local claimed = {};

    -- Process lottery NMs
    for _, ph in ipairs(ph_spawners) do
        -- Use bare key (strips [N] index) for NM file lookup
        local lookup_key = ph.nm_bare_key or ph.nm_key;
        local nm_entry, nm_raw_key = find_nm(lookup_key);
        if not nm_entry then goto next_ph; end

        local nm_name   = nm_entry.mob_name;
        -- Try exact key first, then bare key, then SQL name search
        local nm_mob_id = mob_ids[ph.nm_key] or mob_ids[lookup_key];

        if not nm_mob_id then
            local zone_spawns = self.SpawnByZone[zone_id];
            if zone_spawns then
                local bare_raw = lookup_key:gsub('_', ' ');
                for mid, sp in pairs(zone_spawns) do
                    if sp.RawName == lookup_key or sp.Name:lower() == nm_name:lower()
                    or sp.Name:lower() == bare_raw:lower() then
                        if not nm_mob_id or mid < nm_mob_id then nm_mob_id = mid; end
                    end
                end
            end
        end

        local phs = resolve_ph_ids(
            nm_entry.content, mob_ids, ph.nm_key, nm_mob_id, self.SpawnById);

        -- Attach per-PH respawn time from mob_groups.sql
        for _, p in ipairs(phs) do
            p.Chance      = ph.chance;
            p.NMCooldown  = ph.cooldown;
            if ph.ph_type == 'spawn_mob' then
                -- PH respawn is set by the NM file (e.g. King Arthro sets Knight Crab timers)
                local ph_rmin, ph_rmax = parse_ph_respawn_from_nm(nm_entry.content);
                p.RespawnTime = ph_rmin or self:GetRespawnTime(p.Id, zone_id);
                p.RespawnMax  = ph_rmax;
            else
                p.RespawnTime = self:GetRespawnTime(p.Id, zone_id);
            end
        end

        -- spawn_mob type = true_lottery (100% when all PHs cleared)
        local nm_type;
        if ph.ph_type == 'spawn_mob' then
            nm_type = 'true_lottery';
        else
            nm_type = (ph.cooldown >= 300) and 'timed_lottery' or 'true_lottery';
        end
        local nm_spawn = nm_mob_id and self.SpawnById[nm_mob_id];

        if nms[nm_name] then
            for _, p in ipairs(phs) do
                nms[nm_name].PHs[#nms[nm_name].PHs + 1] = p;
            end
        else
            nms[nm_name] = {
                Name           = nm_name,
                ZoneId         = zone_id,
                NMType         = nm_type,
                NMMobId        = nm_mob_id or 0,
                NMIndex        = nm_spawn and nm_spawn.Index or 0,
                Chance         = ph.chance,
                Cooldown       = ph.cooldown,
                WindowMin      = 0,
                WindowMax      = 0,
                WindowInterval = 0,
                WindowCount    = 0,
                PHs            = phs,
            };
        end

        claimed[nm_raw_key] = true;
        ::next_ph::
    end

    -- Re-classify any lottery NMs whose NM file has timed respawn logic
    -- e.g. King Arthro: Knight Crab has phOnDespawn but KA sets its own respawn timer
    for nm_name, nm in pairs(nms) do
        if nm.NMType == 'true_lottery' or nm.NMType == 'timed_lottery' then
            -- Find the NM file
            local raw_key = nm_name:gsub(' ', '_');
            local nm_file = nm_files[raw_key] or nm_files[nm_name];
            if not nm_file then
                for k, v in pairs(nm_files) do
                    if k:lower() == raw_key:lower() or k:lower() == nm_name:lower() then
                        nm_file = v; break;
                    end
                end
            end
            if nm_file then
                local rmin, rmax, interval, wcount = parse_timed_spawn(nm_file.content);
                if rmin and rmin > 0 then
                    nm.NMType         = 'timed_spawn';
                    nm.WindowMin      = rmin;
                    nm.WindowMax      = rmax;
                    nm.WindowInterval = interval or 0;
                    nm.WindowCount    = wcount   or 0;
                    nm.Cooldown       = 0;
                end
            end
        end
    end

    -- Process timed spawn NMs
    for raw_key, nm_entry in pairs(nm_files) do
        if claimed[raw_key] then goto next_nm; end
        local mob_name = nm_entry.mob_name;
        if nms[mob_name] then goto next_nm; end

        local rmin, rmax, interval, wcount = parse_timed_spawn(nm_entry.content);
        if not rmin then goto next_nm; end

        local nm_mob_id = mob_ids[raw_key];
        if not nm_mob_id then
            local zone_spawns = self.SpawnByZone[zone_id];
            if zone_spawns then
                for mid, sp in pairs(zone_spawns) do
                    if sp.RawName == raw_key or sp.Name:lower() == mob_name:lower() then
                        if not nm_mob_id or mid < nm_mob_id then nm_mob_id = mid; end
                    end
                end
            end
        end

        local nm_spawn = nm_mob_id and self.SpawnById[nm_mob_id];
        nms[mob_name] = {
            Name           = mob_name,
            ZoneId         = zone_id,
            NMType         = 'timed_spawn',
            NMMobId        = nm_mob_id or 0,
            NMIndex        = nm_spawn and nm_spawn.Index or 0,
            Chance         = 100,
            Cooldown       = 0,
            WindowMin      = rmin,
            WindowMax      = rmax,
            WindowInterval = interval or 0,
            WindowCount    = wcount  or 0,
            PHs            = {},
        };

        ::next_nm::
    end

    -- Process NMs that define their own PHs via entity.phList
    -- (e.g. Leaping Lizzy, Carnero, Stray Mary, Valkurm Emperor)
    for fname, nm_entry in pairs(nm_files) do
        if not claimed[fname] then
            local content  = nm_entry.content;
            local mob_name = nm_entry.mob_name;
            -- Must have phList AND spawnPoints to be a trackable lottery NM
            if content:find('entity%.phList') and content:find('entity%.spawnPoints') then
                -- Find the NM's mob_id
                local nm_mob_id = nil;
                local zone_spawns = self.SpawnByZone[zone_id];
                if zone_spawns then
                    for mid, sp in pairs(zone_spawns) do
                        if sp.Name:lower() == mob_name:lower() then
                            if not nm_mob_id or mid < nm_mob_id then nm_mob_id = mid; end
                        end
                    end
                end

                local phs = resolve_ph_ids(content, mob_ids, fname, nm_mob_id, self.SpawnById);
                for _, p in ipairs(phs) do
                    p.RespawnTime = self:GetRespawnTime(p.Id, zone_id);
                end

                if #phs > 0 and not nms[mob_name] then
                    local nm_spawn = nm_mob_id and self.SpawnById[nm_mob_id];
                    nms[mob_name] = {
                        Name           = mob_name,
                        ZoneId         = zone_id,
                        NMType         = 'true_lottery',
                        NMMobId        = nm_mob_id or 0,
                        NMIndex        = nm_spawn and nm_spawn.Index or 0,
                        Chance         = 100,
                        Cooldown       = 0,
                        WindowMin      = 0,
                        WindowMax      = 0,
                        WindowInterval = 0,
                        WindowCount    = 0,
                        PHs            = phs,
                    };
                    claimed[fname] = true;
                end
            end
        end
    end

    return nms;
end;

------------------------------------------------------------
-- Write zone data file
------------------------------------------------------------
import_module.WriteZoneFile = function(self, zone_id, zone_name, nms)
    -- Build loot-only entries: NMs with drop data but no tracking entry
    local loot_only = {};
    if self.Drops and self.Drops[zone_id] then
        for nm_key, drops in pairs(self.Drops[zone_id]) do
            if #drops > 0 then
                -- Find canonical name from the comment (stored as-is in the key)
                -- Check if this NM is already in nms (case-insensitive)
                local already = false;
                for nm_name in pairs(nms) do
                    if nm_name:lower() == nm_key then already = true; break; end
                end
                if not already then
                    -- Capitalize each word for display
                    local canon = nm_key:gsub('(%a)([%w]*)', function(a,b)
                        return a:upper()..b:lower(); end);
                    loot_only[canon] = drops;
                end
            end
        end
    end

    local count = 0;
    for _ in pairs(nms) do count = count + 1; end
    local loot_count = 0;
    for _ in pairs(loot_only) do loot_count = loot_count + 1; end
    if count == 0 and loot_count == 0 then return 0; end

    local path = string.format('%s\\%u.lua', OUTPUTPATH, zone_id);
    local f    = io.open(path, 'w');
    if not f then return 0; end

    f:write('-- Zone: ' .. zone_name .. ' (ID: ' .. tostring(zone_id) .. ')\n');
    f:write('-- Generated by Eggs. Do not edit manually.\n');
    f:write('return {\n');

    for nm_name, nm in pairs(nms) do
        local sname = nm_name:gsub("'", "\\'");
        local ph_parts = {};
        for _, ph in ipairs(nm.PHs) do
            local ph_sname = ph.Name:gsub("'", "\\'");
            ph_parts[#ph_parts + 1] =
                '{Id='          .. tostring(ph.Id)           ..
                ",Name='"       .. ph_sname                  .. "'" ..
                ',Index='       .. tostring(ph.Index)        ..
                ',Chance='      .. tostring(ph.Chance)       ..
                ',NMCooldown='  .. tostring(ph.NMCooldown or 0) ..
                ',RespawnTime=' .. tostring(ph.RespawnTime or 300) .. '}';
        end
        local ph_str = '{' .. table.concat(ph_parts, ',') .. '}';
        local loot_str = 'nil';
        if self.Drops then
            local zone_drops = self.Drops[zone_id];
            local nm_key_lower = nm_name:lower();
            local drops = zone_drops and zone_drops[nm_key_lower];
            if drops and #drops > 0 then
                local loot_parts = {};
                for _, d in ipairs(drops) do
                    local dname = d.Name:gsub("'", "\\'");
                    loot_parts[#loot_parts + 1] =
                        "{Name='" .. dname .. "'" ..
                        ",Rate="     .. tostring(d.Rate) ..
                        ",Type="     .. tostring(d.Type) ..
                        ",GroupId="  .. tostring(d.GroupId or 0) ..
                        ",GroupRate=".. tostring(d.GroupRate or 1000) .. "}";
                end
                loot_str = '{' .. table.concat(loot_parts, ',') .. '}';
            end
        end
        f:write(
            "  ['" .. sname .. "']={" ..
            "Name='"    .. sname                     .. "'," ..
            "ZoneId="   .. tostring(zone_id)         .. "," ..
            "NMType='"  .. tostring(nm.NMType)       .. "'," ..
            "NMMobId="  .. tostring(nm.NMMobId or 0) .. "," ..
            "NMIndex="  .. tostring(nm.NMIndex or 0) .. "," ..
            "Chance="   .. tostring(nm.Chance)       .. "," ..
            "Cooldown=" .. tostring(nm.Cooldown)     .. "," ..
            "WindowMin="     .. tostring(nm.WindowMin)      .. "," ..
            "WindowMax="     .. tostring(nm.WindowMax)      .. "," ..
            "WindowInterval=".. tostring(nm.WindowInterval or 0) .. "," ..
            "WindowCount="   .. tostring(nm.WindowCount or 0)    .. "," ..
            "Loot="     .. loot_str                  .. "," ..
            "PHs="      .. ph_str                    .. "},\n"
        );
    end

    -- Write loot-only entries (popped NMs etc. with no tracking data)
    for nm_name, drops in pairs(loot_only) do
        local sname = nm_name:gsub("'", "\\'");
        local loot_parts = {};
        for _, d in ipairs(drops) do
            local dname = d.Name:gsub("'", "\\'");
            loot_parts[#loot_parts + 1] =
                "{Name='" .. dname .. "'" ..
                ",Rate="     .. tostring(d.Rate) ..
                ",Type="     .. tostring(d.Type) ..
                ",GroupId="  .. tostring(d.GroupId or 0) ..
                ",GroupRate=".. tostring(d.GroupRate or 1000) .. "}";
        end
        local loot_str = '{' .. table.concat(loot_parts, ',') .. '}';
        f:write(
            "  ['" .. sname .. "']={" ..
            "Name='"    .. sname       .. "'," ..
            "ZoneId="   .. tostring(zone_id) .. "," ..
            "NMType='loot_only',"  ..
            "NMMobId=0,NMIndex=0,Chance=0,Cooldown=0,WindowMin=0,WindowMax=0," ..
            "Loot="     .. loot_str   .. "," ..
            "PHs={}},\n"
        );
    end

    f:write('};\n');
    f:close();
    return count;
end;

------------------------------------------------------------
-- Zone name <-> ID map
------------------------------------------------------------
import_module.BuildZoneMap = function(self)
    self.ZoneNameToId = {};
    self.ZoneIdToName = {};
    for id = 0, 300 do
        local name = AshitaCore:GetResourceManager():GetString('zones.names', id);
        if name and name ~= '' then
            local key = name:lower():gsub("'", ''):gsub('%s+', '_'):gsub('[^%w_]', '');
            self.ZoneNameToId[key] = id;
            self.ZoneIdToName[id]  = name;
        end
    end
end;

import_module.FolderToZoneId = function(self, folder_name)
    -- Manual overrides for folders whose names don't normalize to match Ashita zone strings
    local overrides = {
        ['riverne-site_a01']              = 30,
        ['riverne-site_b01']              = 29,
        ['ship_bound_for_selbina_pirates'] = 227,
        ['ship_bound_for_mhaura_pirates']  = 228,
    };
    local lower = folder_name:lower();
    if overrides[lower] then return overrides[lower]; end
    local key = lower:gsub("'", ''):gsub('%s+', '_'):gsub('[^%w_]', '');
    return self.ZoneNameToId[key];
end;

------------------------------------------------------------
-- Manual NM entries for NMs with custom spawn mechanics
-- that can't be auto-detected from LSB scripts
------------------------------------------------------------
import_module.GetManualEntries = function(self, zone_id)
    local entries = {
        -- Zone 30: Riverne - Site #A01
        [30] = {
            ['Carmine Dobsonfly'] = {
                Name           = 'Carmine Dobsonfly',
                ZoneId         = 30,
                NMType         = 'timed_spawn',
                NMMobId        = 16900230,
                NMIndex        = 230,
                Chance         = 100,
                Cooldown       = 0,
                WindowMin      = 75600,  -- 21 hours
                WindowMax      = 86400,  -- 24 hours
                WindowInterval = 0,
                WindowCount    = 0,
                Loot           = self:BuildLootTable(zone_id, 'carmine dobsonfly'),
                PHs            = {},
            },
            ['Heliodromos'] = {
                Name           = 'Heliodromos',
                ZoneId         = 30,
                NMType         = 'timed_spawn',
                NMMobId        = 16900110,
                NMIndex        = 110,
                Chance         = 100,
                Cooldown       = 0,
                WindowMin      = 43200,  -- 12 hours
                WindowMax      = 54000,  -- 15 hours
                WindowInterval = 0,
                WindowCount    = 0,
                Loot           = self:BuildLootTable(zone_id, 'heliodromos'),
                PHs            = {},
            },
        },
    };
    return entries[zone_id];
end;

import_module.BuildLootTable = function(self, zone_id, nm_key_lower)
    if not self.Drops or not self.Drops[zone_id] then return {}; end
    local drops = self.Drops[zone_id][nm_key_lower];
    if not drops then return {}; end
    local loot = {};
    for _, d in ipairs(drops) do
        loot[#loot+1] = {
            Name      = d.Name,
            Rate      = d.Rate,
            Type      = d.Type,
            GroupId   = d.GroupId,
            GroupRate = d.GroupRate,
        };
    end
    return loot;
end;

------------------------------------------------------------
-- Main import pipeline
------------------------------------------------------------
import_module.Run = function(self)
    print(chat.header('Eggs') .. chat.message('Starting import from: ' .. LSB_SERVER));

    if not self:ParseSpawnPoints() then return; end
    coroutine.sleep(0.05);
    if not self:ParseGroups() then return; end
    coroutine.sleep(0.05);
    self:ParseDroplist();
    coroutine.sleep(0.05);

    ashita.fs.create_directory(OUTPUTPATH);
    self:BuildZoneMap();

    local err_f       = io.open(ERRORPATH, 'w');
    local total_zones = 0;
    local total_nms   = 0;
    local errors      = 0;

    local folders = list_subdirs(ZONES_PATH);
    if #folders == 0 then
        print(chat.header('Eggs') .. chat.error('No zone folders found in: ' .. ZONES_PATH));
        if err_f then err_f:close(); end
        return;
    end

    print(chat.header('Eggs') .. chat.message(
        'Found ' .. #folders .. ' zone folders. Processing...'));

    for _, folder in ipairs(folders) do
        local zone_path = ZONES_PATH .. '\\' .. folder;
        local mobs_path = zone_path  .. '\\mobs';
        local lua_files = list_lua_files(mobs_path);

        if #lua_files > 0 then
            local zone_id = self:FolderToZoneId(folder);
            if zone_id then
                local zone_name = self.ZoneIdToName[zone_id] or folder;
                local mob_ids   = self:ParseZoneIDs(zone_path, zone_id);
                local ok, result = pcall(function()
                    return self:ProcessZone(zone_id, zone_name, zone_path, mob_ids);
                end);
                if ok then
                    -- Inject manually defined NMs for zones with custom spawn mechanics
                    local manual = self:GetManualEntries(zone_id);
                    if manual then
                        for nm_name, entry in pairs(manual) do
                            if not result[nm_name] then
                                result[nm_name] = entry;
                            end
                        end
                    end
                    local n = self:WriteZoneFile(zone_id, zone_name, result);
                    if n > 0 then
                        total_zones = total_zones + 1;
                        total_nms   = total_nms + n;
                    end
                else
                    errors = errors + 1;
                    if err_f then
                        err_f:write('ERROR zone=' .. folder .. ': ' .. tostring(result) .. '\n');
                    end
                end
            else
                if err_f then
                    err_f:write('WARN: no zone ID for folder: ' .. folder .. '\n');
                end
            end

            if (total_zones + errors) % 20 == 0 and (total_zones + errors) > 0 then
                coroutine.sleep(0.05);
                print(chat.header('Eggs') .. chat.message(
                    'Progress: ' .. total_zones .. ' zones, ' .. total_nms .. ' NMs...'));
            end
        end
    end

    if err_f then err_f:close(); end
    print(chat.header('Eggs') .. chat.message(
        'Import done! ' .. total_zones .. ' zones, ' .. total_nms ..
        ' NMs. ' .. errors .. ' errors.'));

    -- Free heavy import tables before reloading to keep memory usage down
    self.SpawnById   = nil;
    self.SpawnByZone = nil;
    self.Groups      = nil;
    self.Drops       = nil;
    self.ZoneNameToId = nil;
    self.ZoneIdToName = nil;
    collectgarbage('collect');

    -- Reload all NM data from freshly written files
    gNmData.AllNMsLoaded = false;
    gNmData.CurrentZone  = -1;
    gNmData:Load(AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0));
    gNmData:LoadAllForBrowser();
end;

return import_module;
