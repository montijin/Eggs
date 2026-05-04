require('common');
local chat = require('chat');
------------------------------------------------------------
-- nm_data.lua  (Eggs v1.0 - by Monti)
-- Loads per-zone NM data from addons/eggs/data/<zone_id>.lua
------------------------------------------------------------

local nm_data = {};

nm_data.CurrentZone  = -1;
nm_data.NMs          = {};   -- current zone NMs by name
nm_data.PHLookup     = {};   -- spawn-point index -> nm_name (current zone)
nm_data.AllNMs       = {};   -- flat list for browser
nm_data.AllNMsLoaded = false;
nm_data.AllNMsByName = {};   -- [name] = entry, across all loaded zones

------------------------------------------------------------
-- Load zone-specific data file
------------------------------------------------------------
nm_data.Load = function(self, zone)
    if zone == self.CurrentZone then return; end
    self.CurrentZone = zone;
    self.NMs      = {};
    self.PHLookup = {};
    if zone == 0 then return; end

    local path = addon.path .. 'data\\' .. zone .. '.lua';
    if not ashita.fs.exists(path) then return; end

    local loader, err = loadfile(path);
    if not loader then
        print(chat.header('Eggs') .. chat.error('Failed loading data: ' .. tostring(err)));
        return;
    end

    local ok, result = pcall(loader);
    if not ok or type(result) ~= 'table' then return; end

    for nm_name, entry in pairs(result) do
        self.NMs[nm_name] = entry;
        -- Build PH lookup by spawn-point index ONLY (no name fallback)
        if entry.PHs then
            for _, ph in ipairs(entry.PHs) do
                if ph.Index and ph.Index > 0 then
                    self.PHLookup[ph.Index] = nm_name;
                end
            end
        end
    end
end;

------------------------------------------------------------
-- Load all zones for browser (lazy)
------------------------------------------------------------
nm_data.LoadAllForBrowser = function(self)
    if self.AllNMsLoaded then return; end
    self.AllNMs       = {};
    self.AllNMsByName = {};

    local data_path     = addon.path .. 'data\\';
    local data_path_fwd = addon.path .. 'data/';
    if not ashita.fs.exists(data_path_fwd) then
        print(chat.header('Eggs') .. chat.error('No data folder. Run /eggs import first.'));
        return;
    end

    -- Enumerate by trying all valid zone IDs (0-512)
    -- This avoids io.popen which can fail silently at Ashita startup
    local lua_files = {};
    for zone_id = 0, 512 do
        local fpath = data_path .. zone_id .. '.lua';
        if ashita.fs.exists(data_path_fwd .. zone_id .. '.lua') then
            lua_files[#lua_files+1] = zone_id .. '.lua';
        end
    end

    for _, fname in ipairs(lua_files) do
        local zone_id = tonumber(fname:match('^(%d+)%.lua$'));
        if zone_id then
            local loader = loadfile(data_path .. fname);
            if loader then
                local ok, result = pcall(loader);
                if ok and type(result) == 'table' then
                    local zone_name = AshitaCore:GetResourceManager():GetString('zones.names', zone_id)
                                   or ('Zone ' .. zone_id);
                    for nm_name, entry in pairs(result) do
                        local rec = {
                            Name           = nm_name,
                            ZoneId         = zone_id,
                            ZoneName       = zone_name,
                            NMType         = entry.NMType         or 'unknown',
                            Chance         = entry.Chance         or 0,
                            Cooldown       = entry.Cooldown       or 0,
                            WindowMin      = entry.WindowMin      or 0,
                            WindowMax      = entry.WindowMax      or 0,
                            WindowInterval = entry.WindowInterval or 0,
                            WindowCount    = entry.WindowCount    or 0,
                            NMMobId        = entry.NMMobId        or 0,
                            PHs            = entry.PHs            or {},
                            Loot           = entry.Loot           or {},
                        };
                        -- loot_only entries are searchable but don't appear in browser/tracker
                        if entry.NMType ~= 'loot_only' then
                            self.AllNMs[#self.AllNMs+1] = rec;
                        end
                        self.AllNMsByName[nm_name] = rec;
                    end
                end
            end
        end
    end

    table.sort(self.AllNMs, function(a, b)
        if a.ZoneName ~= b.ZoneName then return a.ZoneName < b.ZoneName; end
        return a.Name < b.Name;
    end);

    self.AllNMsLoaded = true;
    print(chat.header('Eggs') .. chat.message(
        'Browser loaded ' .. #self.AllNMs .. ' NMs.'));
end;

------------------------------------------------------------
-- Look up NM by spawn-point index (mob_id % 1024)
------------------------------------------------------------
nm_data.GetNMForPH = function(self, sp_index)
    if sp_index and sp_index > 0 then
        return self.PHLookup[sp_index];
    end
    return nil;
end;

------------------------------------------------------------
-- Get NM entry from current zone
------------------------------------------------------------
nm_data.GetNM = function(self, nm_name)
    return self.NMs[nm_name];
end;

------------------------------------------------------------
-- Get NM entry from any zone (for /eggs <name> cross-zone)
------------------------------------------------------------
nm_data.GetNMAnyZone = function(self, nm_name)
    -- Check current zone first (always up to date)
    if self.NMs[nm_name] then return self.NMs[nm_name]; end
    -- Then check all-zones cache
    if self.AllNMsByName[nm_name] then
        return self.AllNMsByName[nm_name];
    end
    -- Case-insensitive search across both
    local lower = nm_name:lower();
    for name, entry in pairs(self.NMs) do
        if name:lower() == lower then return entry; end
    end
    for name, entry in pairs(self.AllNMsByName) do
        if name:lower() == lower then return entry; end
    end
    return nil;
end;

------------------------------------------------------------
-- Get PH list for an NM
------------------------------------------------------------
nm_data.GetPHList = function(self, nm_name)
    local nm = self.NMs[nm_name] or self.AllNMsByName[nm_name];
    if not nm or not nm.PHs then return {}; end
    return nm.PHs;
end;

return nm_data;
