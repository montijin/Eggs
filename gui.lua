require('common');
local chat  = require('chat');
local imgui = require('imgui');
------------------------------------------------------------
-- gui.lua  (Eggs v1.0 - by MNT)
-- Window 1: Tracker       - tracked NMs with timers
-- Window 2: PH Detail     - per-NM PH list (/eggs <name>)
-- Window 3: PH Popup      - auto-shows when targeting a PH
-- Window 4: Settings      - sound, alarm, display options
-- Window 5: NM Browser    - zone-grouped checklist
------------------------------------------------------------

local gui = {};

------------------------------------------------------------
-- Color helpers
------------------------------------------------------------
local C = {
    GOLD       = { 0.85, 0.65, 0.20, 1.0 },
    GREEN      = { 0.35, 0.85, 0.40, 1.0 },
    RED        = { 0.85, 0.30, 0.25, 1.0 },
    YELLOW     = { 0.95, 0.85, 0.20, 1.0 },
    DIM        = { 0.55, 0.55, 0.55, 1.0 },
    WHITE      = { 1.0,  1.0,  1.0,  1.0 },
    OPEN       = { 0.30, 0.95, 0.50, 1.0 },
    WAITING    = { 0.95, 0.70, 0.20, 1.0 },
    EXPIRED    = { 0.40, 0.40, 0.40, 1.0 },
    MAGENTA    = { 0.95, 0.20, 0.90, 1.0 },   -- NM is UP!
    -- NM Type colors
    TIMED      = { 0.35, 0.65, 0.95, 1.0 },   -- Blue
    TLOTTO     = { 0.75, 0.40, 0.95, 1.0 },   -- Purple
    TRUELOTTO  = { 0.95, 0.80, 0.20, 1.0 },   -- Gold
};

local NM_TYPE_LABEL = {
    timed_spawn    = 'Timed',
    timed_lottery  = 'Timed Lottery',
    true_lottery   = 'True Lottery',
};
local NM_TYPE_COLOR = {
    timed_spawn    = C.TIMED,
    timed_lottery  = C.TLOTTO,
    true_lottery   = C.TRUELOTTO,
};

local function nm_type_label(t) return NM_TYPE_LABEL[t] or '?'; end
local function nm_type_color(t) return NM_TYPE_COLOR[t] or C.DIM; end

-- Format mob ID per user preference
local function fmt_id(id)
    if not id or id == 0 then return '---'; end
    if gSettings.short_ids then
        return string.format('%03d', id % 1000);
    end
    return tostring(id);
end

local function fmt_time(secs) return gTracker:FormatTime(secs); end

------------------------------------------------------------
-- State
------------------------------------------------------------
gui.DetailTarget      = nil;
gui.PHPopupNM         = nil;
gui.PHPopupPHName     = nil;
gui.PHPopupMobId      = nil;
gui.PHPopupTimer      = 0;
gui.NMPopupName       = nil;
gui.NMPopupMobId      = nil;
gui.CurrentTarget     = nil;
gui.CurrentTargetName = nil;
gui.CurrentTargetId   = nil;
gui.LastSeenAlive     = {};  -- [mob_id] = os.time() when last targeted (PHs)
gui.LastSeenNMAlive   = {};  -- [nm_name] = os.time() when NM last targeted
gui.NMConfirmedUp     = {};  -- [nm_name] = true once seen, persists until death recorded

gui.BrowserSearch     = { '' };
gui.BrowserZones      = {};
gui.ConfirmUntrack    = nil;  -- nm_name pending confirmation to untrack
gui._confirm_popup_open = false;
gui.ExpandedTrackers  = {};  -- [nm_name] = bool (for multi-PH collapsible)
gui.LootTarget        = nil;
gui.LootVisible       = false;

gui._tracker_open     = { true  };
gui._detail_open      = { false };
gui._popup_open       = { true  };
gui._nm_popup_open    = { true  };
gui._settings_open    = { false };
gui._browser_open     = { false };

------------------------------------------------------------
gui.Initialize = function(self)
    self._tracker_open[1]  = gSettings.tracker_visible  or true;
    self._detail_open[1]   = gSettings.ph_detail_visible or false;
    self._settings_open[1] = gSettings.settings_visible  or false;
    self._browser_open[1]  = gSettings.nm_browser_visible or false;
end;

-- Returns 'alive', 'unknown', or nil (if timer is active — caller handles dead/unconfirmed)
-- 'alive'   = currently targeted OR seen within timeout window
-- 'unknown' = never seen, or last seen longer ago than ph_alive_timeout
gui.GetPHAliveStatus = function(self, mob_id)
    if self.CurrentTargetId == mob_id then return 'alive'; end
    local last = self.LastSeenAlive[mob_id];
    if last then
        local timeout = gSettings.ph_alive_timeout or 60;
        if timeout == 0 or (os.time() - last) <= timeout then
            return 'alive';
        end
    end
    return 'unknown';
end;

-- Returns 'alive', 'unknown', or 'unseen'
-- 'alive'   = currently targeted OR seen within timeout
-- 'unknown' = was seen but timeout expired (NM still out there somewhere)
-- 'unseen'  = never confirmed alive this session
gui.GetNMAliveStatus = function(self, nm_name)
    if self.CurrentTargetName == nm_name then return 'alive'; end
    if not self.NMConfirmedUp[nm_name] then return 'unseen'; end
    -- Was seen - check if still within timeout
    local last = self.LastSeenNMAlive[nm_name];
    if last then
        local timeout = gSettings.ph_alive_timeout or 60;
        if timeout == 0 or (os.time() - last) <= timeout then
            return 'alive';
        end
    end
    return 'unknown';
end;

gui.ShowLootWindow = function(self, nm_name)
    local nm = gNmData:GetNMAnyZone(nm_name);
    if not nm then
        print(chat.header('Eggs') .. chat.message('NM not found: ' .. nm_name));
        return;
    end
    if not nm.Loot or #nm.Loot == 0 then
        print(chat.header('Eggs') .. chat.message('No loot data for: ' .. nm.Name .. '. Run /eggs import to generate loot data.'));
        return;
    end
    self.LootTarget  = nm.Name;
    self.LootVisible = true;
end;

gui.SetDetailTarget = function(self, nm_name)
    -- Search all loaded data, not just current zone
    local nm = gNmData:GetNMAnyZone(nm_name);
    if not nm then
        print(chat.header('Eggs') .. chat.message('Notorious Monster not found: ' .. nm_name));
        return;
    end
    -- Use canonical name from data so all downstream key lookups match
    self.DetailTarget         = nm.Name or nm_name;
    self._detail_open[1]      = true;
    gSettings.ph_detail_visible = true;
end;

gui.ShowPHPopup = function(self, nm_name, ph_name, mob_id)
    self.PHPopupNM     = nm_name;
    self.PHPopupPHName = ph_name;
    self.PHPopupMobId  = mob_id;
    self.PHPopupTimer  = 9999;  -- stays open while targeting
    self._popup_open[1] = true;
end;

gui.ShowNMPopup = function(self, nm_name, mob_id)
    self.NMPopupName      = nm_name;
    self.NMPopupMobId     = mob_id;
    self._nm_popup_open[1] = true;
end;

gui.HandleTargetChange = function(self, target_index)
    self.CurrentTarget = target_index;
    if not target_index or target_index == 0 then
        self.CurrentTargetName = nil;
        self.CurrentTargetId   = nil;
        -- Close popups when target lost
        if self.PHPopupTimer == 9999 then
            self.PHPopupNM    = nil;
            self.PHPopupTimer = 0;
        end
        self.NMPopupName = nil;
        return;
    end
    local em     = AshitaCore:GetMemoryManager():GetEntity();
    local mob_id = em:GetServerId(target_index);
    local sp_idx = (mob_id and mob_id > 0) and (mob_id % 1024) or target_index;
    self.CurrentTargetName = em:GetName(target_index);
    self.CurrentTargetId   = mob_id;

    if gSettings.debug_mode then
        local nm_match = gNmData:GetNMForPH(sp_idx);
        print(chat.header('Eggs') .. chat.message(string.format(
            'Target: index=%d mob_id=%d sp_idx=%d name=%s ph_match=%s',
            target_index, mob_id or 0, sp_idx,
            self.CurrentTargetName or '?', nm_match or 'none')));
    end

    local nm_name = gNmData:GetNMForPH(sp_idx);
    if nm_name then
        self:ShowPHPopup(nm_name, self.CurrentTargetName, mob_id);
        -- Confirm this PH was seen alive (clears unconfirmed state)
        if not gSettings.ph_confirmed then gSettings.ph_confirmed = {}; end
        gSettings.ph_confirmed[mob_id] = true;
        -- Record last-seen-alive timestamp for Unknown status timeout
        self.LastSeenAlive[mob_id] = os.time();
        self.NMPopupName = nil;
    else
        -- Check if the target is a tracked or known NM itself
        if self.CurrentTargetName and self.CurrentTargetName ~= '' then
            local nm_entry = gNmData:GetNM(self.CurrentTargetName) or
                             gNmData:GetNMAnyZone(self.CurrentTargetName);
            if nm_entry and nm_entry.NMType ~= 'loot_only' and
               (gSettings.tracked and gSettings.tracked[nm_entry.Name] or
                (nm_entry.PHs and #nm_entry.PHs > 0) or
                nm_entry.NMType == 'timed_spawn') then
                self.LastSeenNMAlive[nm_entry.Name] = os.time();
                self.NMConfirmedUp[nm_entry.Name]   = true;
                self:ShowNMPopup(nm_entry.Name, mob_id);
            else
                self.NMPopupName = nil;
            end
        else
            self.NMPopupName = nil;
        end
        -- Moved off a PH - close PH popup
        if self.PHPopupTimer == 9999 then
            self.PHPopupNM    = nil;
            self.PHPopupTimer = 0;
        end
    end
end;

------------------------------------------------------------
-- Style helpers
------------------------------------------------------------
local function push_style(tr, tg, tb, br, bg, bb)
    imgui.PushStyleColor(ImGuiCol_TitleBg,       { tr,       tg,       tb,       0.95 });
    imgui.PushStyleColor(ImGuiCol_TitleBgActive,  { tr+0.05, tg+0.05, tb+0.05, 0.98 });
    imgui.PushStyleColor(ImGuiCol_WindowBg,       { 0.06, 0.06, 0.08, 0.95 });
    imgui.PushStyleColor(ImGuiCol_Border,         { br, bg, bb, 0.85 });
end

------------------------------------------------------------
-- Window 1: Tracker
------------------------------------------------------------
gui.RenderTrackerWindow = function(self)
    if not gSettings.tracker_visible then return; end

    -- Size window to exactly fit scaled columns (no dead space, no cutoff)
    local _sc = gSettings.ui_scale or 1.0;
    local _col_total = math.floor((155+105+90+85+46+26) * _sc) + 18;
    imgui.SetNextWindowSizeConstraints({ _col_total, 60 }, { _col_total, 9999 });
    imgui.SetNextWindowPos({ gSettings.tracker_pos[1], gSettings.tracker_pos[2] }, ImGuiCond_FirstUseEver);
    push_style(0.10, 0.07, 0.02, 0.55, 0.40, 0.05);

    if imgui.Begin('Eggs##tracker', self._tracker_open, ImGuiWindowFlags_None) then
        self:_ApplyScale();
        local p = { imgui.GetWindowPos() };
        gSettings.tracker_pos = { p[1], p[2] };

        imgui.PushStyleColor(ImGuiCol_Button, { 0.22, 0.16, 0.04, 1.0 });
        if imgui.SmallButton(' Browser ')  then gSettings.nm_browser_visible = not gSettings.nm_browser_visible; if gSettings.nm_browser_visible then gNmData:LoadAllForBrowser(); end gSaveSettings(); end
        imgui.SameLine();
        if imgui.SmallButton(' Settings ') then gSettings.settings_visible = not gSettings.settings_visible; gSaveSettings(); end
        imgui.PopStyleColor(1);
        imgui.SameLine();
        imgui.PushStyleColor(ImGuiCol_Button, { 0.30, 0.10, 0.10, 1.0 });
        if imgui.SmallButton(' Clear Monitoring ') then
            -- Remove all tracked NMs and their timers
            gSettings.tracked  = {};
            gSettings.tod_data = {};
            gTracker.ActiveTimers = T{};
            gSaveSettings();
        end
        imgui.PopStyleColor(1);
        imgui.SameLine();
        imgui.TextColored(C.DIM, '  /eggs <NM Name> for detail');
        imgui.Separator();

        if next(gSettings.tracked) == nil then
            imgui.Spacing();
            imgui.TextColored(C.DIM, '  No NMs tracked. Open Browser to add NMs.');
        else
            imgui.Columns(4, 'tcols', true);
            do
                local sc = gSettings.ui_scale or 1.0;
                imgui.SetColumnWidth(0, math.floor(175 * sc));
                imgui.SetColumnWidth(1, math.floor(115 * sc));
                imgui.SetColumnWidth(2, math.floor(120 * sc));
                imgui.SetColumnWidth(3, math.floor(130 * sc));
            end

            imgui.TextColored(C.GOLD, 'NM Name');  imgui.NextColumn();
            imgui.TextColored(C.GOLD, 'Type');     imgui.NextColumn();
            imgui.TextColored(C.GOLD, 'Status');   imgui.NextColumn();
            imgui.TextColored(C.GOLD, 'Timer');    imgui.NextColumn();
            imgui.Separator();

            local to_remove = {};

            for nm_name, track_info in pairs(gSettings.tracked) do
                local nm_entry = gNmData:GetNM(nm_name) or gNmData:GetNMAnyZone(nm_name);
                local nm_type  = nm_entry and nm_entry.NMType or 'unknown';

                local nm_timer  = nil;
                local ph_timers = {};
                for key, entry in pairs(gTracker.ActiveTimers) do
                    if entry.nm_name == nm_name then
                        if entry.type == 'nm' then nm_timer = {key=key, e=entry};
                        elseif entry.type == 'ph' then ph_timers[#ph_timers+1] = {key=key, e=entry}; end
                    end
                end

                local has_multi_ph = nm_entry and nm_entry.PHs and #nm_entry.PHs > 1;
                local is_expanded  = self.ExpandedTrackers[nm_name];

                -- Col 0: Name + inline X button
                imgui.PushStyleColor(ImGuiCol_Button, {0,0,0,0});
                imgui.PushStyleColor(ImGuiCol_ButtonHovered, {0.2,0.2,0.3,0.5});
                if has_multi_ph then
                    local arrow = is_expanded and 'v ' or '> ';
                    if imgui.SmallButton(arrow .. nm_name .. '##tr_' .. nm_name) then
                        self.ExpandedTrackers[nm_name] = not is_expanded;
                    end
                else
                    if imgui.SmallButton(nm_name .. '##tr_' .. nm_name) then
                        self:SetDetailTarget(nm_name);
                        gSettings.ph_detail_visible = true;
                        gSaveSettings();
                    end
                end
                imgui.PopStyleColor(2);
                imgui.SameLine();
                imgui.PushStyleColor(ImGuiCol_Button, { 0.45, 0.10, 0.10, 1.0 });
                if imgui.SmallButton('X##rm_' .. nm_name) then
                    if gSettings.confirm_untrack ~= false then
                        self.ConfirmUntrack = nm_name;
                    else
                        to_remove[#to_remove+1] = nm_name;
                    end
                end
                imgui.PopStyleColor(1);
                imgui.NextColumn();

                -- Col 1: Type
                imgui.TextColored(nm_type_color(nm_type), nm_type_label(nm_type));
                imgui.NextColumn();

                -- Col 2 & 3: Status and Timer
                -- Compute PH timer state once for both columns
                local ph_min_rem = nil;
                local ph_any_active = false;
                for _, pt in ipairs(ph_timers) do
                    local r = gTracker:GetRemaining(pt.e);
                    if ph_min_rem == nil or r < ph_min_rem then ph_min_rem = r; end
                    if r > 0 then ph_any_active = true; end
                end

                if nm_timer then
                    local nm_alive = self:GetNMAliveStatus(nm_name);
                    if nm_alive == 'alive' then
                        imgui.TextColored(C.MAGENTA, 'NM is UP!');
                    elseif nm_alive == 'unknown' then
                        imgui.TextColored(C.DIM, 'Unknown');
                    else
                    local st, uo, uc = gTracker:GetNMWindowStatus(nm_timer.e);
                    if st == 'waiting' then
                        imgui.TextColored(C.WAITING, 'Cooldown');
                    elseif st == 'open' then
                        local interval = nm_entry and nm_entry.WindowInterval or 0;
                        local wcount   = nm_entry and nm_entry.WindowCount    or 0;
                        if interval > 0 and wcount > 1 then
                            local elapsed   = os.time() - nm_timer.e.tod_os;
                            local wmin      = nm_timer.e.respawn_secs;
                            local wins_past = math.floor((elapsed - wmin) / interval);
                            local disp_win  = math.min(wins_past + 2, wcount);
                            imgui.TextColored(C.OPEN, string.format('Eligible (%d/%d)', disp_win, wcount));
                        else
                            imgui.TextColored(C.OPEN, 'Eligible');
                        end
                    elseif st == 'expired' then
                        local interval = nm_entry and nm_entry.WindowInterval or 0;
                        local wcount   = nm_entry and nm_entry.WindowCount    or 0;
                        if interval > 0 and wcount > 1 then
                            local elapsed   = os.time() - nm_timer.e.tod_os;
                            local close_at  = nm_timer.e.window_secs;
                            local past_last = elapsed - close_at;
                            if past_last <= 60 then
                                imgui.TextColored(C.OPEN, string.format('Open (%d/%d)', wcount, wcount));
                            else
                                imgui.TextColored(C.DIM, 'Unknown');
                            end
                        else
                            imgui.TextColored(C.EXPIRED, 'Expired');
                        end
                    end
                    end -- nm_alive check
                else
                    local nm_alive = self:GetNMAliveStatus(nm_name);
                    if nm_alive == 'alive' then
                        imgui.TextColored(C.MAGENTA, 'NM is UP!');
                    elseif nm_alive == 'unknown' then
                        imgui.TextColored(C.DIM, 'Unknown');
                    elseif ph_any_active then
                        imgui.TextColored(C.YELLOW, 'PH Dead');
                    elseif ph_min_rem ~= nil and ph_min_rem <= 0 then
                        imgui.TextColored(C.GREEN, 'PH Spawned');
                    else
                        imgui.TextColored(C.GREEN, 'Monitoring');
                    end
                end
                imgui.NextColumn();

                if nm_timer then
                    local nm_alive = self:GetNMAliveStatus(nm_name);
                    if nm_alive == 'alive' or nm_alive == 'unknown' then
                        imgui.TextColored(C.DIM, '---');
                    else
                    local st, uo, uc = gTracker:GetNMWindowStatus(nm_timer.e);
                    local interval = nm_entry and nm_entry.WindowInterval or 0;
                    local wcount   = nm_entry and nm_entry.WindowCount    or 0;
                    local has_windows = interval > 0 and wcount > 1;

                    if st == 'waiting' then
                        if has_windows then
                            imgui.Text(string.format('%s (1/%d)', fmt_time(uo), wcount));
                        else
                            imgui.Text(fmt_time(uo));
                        end
                    elseif st == 'open' then
                        if has_windows then
                            local elapsed      = os.time() - nm_timer.e.tod_os;
                            local wmin         = nm_timer.e.respawn_secs;
                            local wmax         = nm_timer.e.window_secs;
                            local wins_past    = math.floor((elapsed - wmin) / interval);
                            local disp_win     = math.min(wins_past + 2, wcount);
                            local next_boundary;
                            if disp_win >= wcount then
                                next_boundary = wmax;
                            else
                                next_boundary = wmin + (wins_past + 1) * interval;
                            end
                            local secs_to_next  = next_boundary - elapsed;
                            imgui.TextColored(C.OPEN, string.format('%s (%d/%d)',
                                fmt_time(secs_to_next), disp_win, wcount));
                        elseif uc then
                            imgui.TextColored(C.OPEN, 'Closes: ' .. fmt_time(uc));
                        elseif ph_any_active and ph_min_rem and ph_min_rem > 0 then
                            imgui.TextColored(C.YELLOW, fmt_time(ph_min_rem));
                        else
                            imgui.TextColored(C.OPEN, 'Open');
                        end
                    elseif st == 'expired' then
                        if has_windows then
                            local elapsed   = os.time() - nm_timer.e.tod_os;
                            local close_at  = nm_timer.e.window_secs;
                            local past_last = elapsed - close_at;
                            if past_last <= 60 then
                                imgui.TextColored(C.OPEN, string.format('Open (%d/%d)', wcount, wcount));
                            else
                                imgui.TextColored(C.DIM, '---');
                            end
                        else
                            imgui.TextColored(C.OPEN, 'Open');
                        end
                    end -- st check
                    end -- nm_alive else
                elseif self:GetNMAliveStatus(nm_name) ~= 'unseen' then
                    imgui.TextColored(C.DIM, '---');
                elseif ph_any_active then
                    imgui.TextColored(C.YELLOW, fmt_time(ph_min_rem));
                else
                    imgui.TextColored(C.DIM, '---');
                end
                imgui.NextColumn();

                -- Expanded PH sub-rows
                if has_multi_ph and is_expanded and nm_entry then
                    for _, ph in ipairs(nm_entry.PHs) do
                        local pkey = string.format('ph:%d', ph.Id or 0);
                        local pt   = gTracker.ActiveTimers[pkey];
                        local rem  = pt and gTracker:GetRemaining(pt) or nil;
                        -- Unconfirmed state
                        local ph_expired = pt and gTracker:GetRemaining(pt) <= 0;
                        local ph_unconf  = ph_expired and
                            (not gSettings.ph_confirmed or gSettings.ph_confirmed[ph.Id] == nil);
                        if ph_unconf then
                            imgui.TextColored({ 0.45, 0.45, 0.45, 1.0 }, '    ' .. ph.Name .. ' [' .. fmt_id(ph.Id) .. '] (?)');
                        else
                            imgui.TextColored(C.DIM, '    ' .. ph.Name .. ' [' .. fmt_id(ph.Id) .. ']');
                        end
                        imgui.NextColumn();
                        imgui.NextColumn();
                        if pt then
                            local r = gTracker:GetRemaining(pt);
                            if r > 0 then imgui.TextColored(C.RED, 'Dead');
                            elseif ph_unconf then imgui.TextColored({ 0.55, 0.55, 0.55, 1.0 }, 'Unconfirmed');
                            else imgui.TextColored(C.GREEN, 'Alive'); end
                        else
                            local alive_status = self:GetPHAliveStatus(ph.Id);
                            if alive_status == 'alive' then
                                imgui.TextColored(C.GREEN, 'Alive');
                            else
                                imgui.TextColored(C.DIM, 'Unknown');
                            end
                        end
                        imgui.NextColumn();
                        if rem and rem > 0 then imgui.TextColored(C.YELLOW, fmt_time(rem));
                        elseif pt then imgui.TextColored(C.GREEN, 'Spawned');
                        else imgui.TextColored(C.DIM, '---'); end
                        imgui.NextColumn();
                    end
                end

                -- Single PH sub-rows
                if not has_multi_ph then
                    for _, pt in ipairs(ph_timers) do
                        local rem = gTracker:GetRemaining(pt.e);
                        imgui.TextColored(C.DIM, '  > ' .. (pt.e.ph_name or 'PH')); imgui.NextColumn();
                        imgui.NextColumn();
                        imgui.TextColored(C.DIM, 'Respawning'); imgui.NextColumn();
                        if rem > 0 then imgui.TextColored(C.YELLOW, fmt_time(rem));
                        else imgui.TextColored(C.GREEN, 'Spawned'); end
                        imgui.NextColumn();
                    end
                end
            end

            imgui.Columns(1);

            for _, nm_name in ipairs(to_remove) do
                gSettings.tracked[nm_name] = nil;
                local del = {};
                for key, entry in pairs(gTracker.ActiveTimers) do
                    if entry.nm_name == nm_name then del[#del+1] = key; end
                end
                for _, k in ipairs(del) do gTracker:RemoveTimer(k); end
                gSaveSettings();
            end

        end  -- tracked NMs
    end  -- Begin
    self:_PopScale();
    imgui.End();
    imgui.PopStyleColor(4);
    if not self._tracker_open[1] then gSettings.tracker_visible = false; gSaveSettings(); end
end;

------------------------------------------------------------
-- Window 2: PH Detail
------------------------------------------------------------
gui.RenderDetailWindow = function(self)
    if not gSettings.ph_detail_visible or not self.DetailTarget then return; end

    local _sc2 = gSettings.ui_scale or 1.0;
    local _det_w = math.floor((110+75+55+65+55) * _sc2) + 18;
    imgui.SetNextWindowSizeConstraints({ _det_w, 120 }, { _det_w, 9999 });
    imgui.SetNextWindowPos({ gSettings.ph_detail_pos[1], gSettings.ph_detail_pos[2] }, ImGuiCond_FirstUseEver);
    push_style(0.05, 0.10, 0.18, 0.10, 0.35, 0.65);

    local title = 'Eggs - PH Detail: ' .. self.DetailTarget .. '##detail';
    if imgui.Begin(title, self._detail_open, ImGuiWindowFlags_HorizontalScrollbar) then
        self:_ApplyScale();
        local p = { imgui.GetWindowPos() };
        gSettings.ph_detail_pos = { p[1], p[2] };

        -- Try current zone first, then all zones
        local nm = gNmData:GetNM(self.DetailTarget) or gNmData:GetNMAnyZone(self.DetailTarget);
        if not nm then
            imgui.TextColored(C.RED, 'Notorious Monster not found: ' .. self.DetailTarget);
        else
            imgui.TextColored(C.GOLD, nm.Name);
            imgui.SameLine();
            imgui.TextColored(nm_type_color(nm.NMType), '  [' .. nm_type_label(nm.NMType) .. ']');
            imgui.SameLine();
            local zone_name = AshitaCore:GetResourceManager():GetString('zones.names', nm.ZoneId) or ('Zone ' .. nm.ZoneId);
            imgui.TextColored(C.DIM, '  ' .. zone_name);
            -- Show NM alive status if targeting it or seen recently
            local nm_alive = self:GetNMAliveStatus(nm.Name);
            if nm_alive == 'alive' then
                imgui.SameLine();
                imgui.TextColored(C.MAGENTA, '  UP!');
            elseif nm_alive == 'unknown' then
                imgui.SameLine();
                imgui.TextColored(C.DIM, '  Unknown');
            end

            -- Type info line
            if nm.NMType == 'timed_lottery' or nm.NMType == 'true_lottery' then
                -- Check if NM is currently on cooldown
                local nm_key   = 'nm:' .. nm.Name:gsub('[^%w]','_');
                local nm_timer = gTracker.ActiveTimers[nm_key];
                if nm_timer then
                    local st, uo = gTracker:GetNMWindowStatus(nm_timer);
                    if st == 'waiting' and uo > 0 then
                        imgui.TextColored(C.WAITING, string.format(
                            'Spawn Chance: %d%%   Time until spawnable: %s',
                            nm.Chance or 0, fmt_time(uo)));
                    else
                        imgui.TextColored(C.OPEN, string.format(
                            'Spawn Chance: %d%%   NM is eligible to spawn!',
                            nm.Chance or 0));
                    end
                else
                    imgui.TextColored(C.DIM, string.format(
                        'Spawn Chance: %d%%   NM Cooldown after death: %s',
                        nm.Chance or 0,
                        nm.Cooldown and nm.Cooldown > 0 and fmt_time(nm.Cooldown) or 'None'));
                end
            elseif nm.NMType == 'timed_spawn' then
                if nm.WindowMax and nm.WindowMax > nm.WindowMin then
                    imgui.TextColored(C.DIM, 'Spawn window: ' .. fmt_time(nm.WindowMin) .. ' - ' .. fmt_time(nm.WindowMax));
                else
                    imgui.TextColored(C.DIM, 'Respawn: ' .. fmt_time(nm.WindowMin));
                end
            end

            imgui.Separator();
            imgui.TextColored(C.GOLD, 'Placeholders:');
            imgui.Spacing();

            local ph_list = nm.PHs or {};
            if #ph_list == 0 then
                imgui.TextColored(C.DIM, '  No placeholder data.');
                if nm.NMType == 'timed_spawn' then
                    imgui.TextColored(C.DIM, '  (Timed Spawn NMs do not have placeholders)');
                end
            else
                imgui.Columns(5, 'ph_detail_cols', true);
                do
                    local sc = gSettings.ui_scale or 1.0;
                    imgui.SetColumnWidth(0, math.floor(110 * sc));
                    imgui.SetColumnWidth(1, math.floor(75  * sc));
                    imgui.SetColumnWidth(2, math.floor(55  * sc));
                    imgui.SetColumnWidth(3, math.floor(65  * sc));
                    imgui.SetColumnWidth(4, math.floor(55  * sc));
                end

                imgui.TextColored(C.GOLD, 'PH Name');      imgui.NextColumn();
                imgui.TextColored(C.GOLD, 'ID');           imgui.NextColumn();
                imgui.TextColored(C.GOLD, 'Status');       imgui.NextColumn();
                imgui.TextColored(C.GOLD, 'Respawn');      imgui.NextColumn();
                imgui.TextColored(C.GOLD, 'Chance');       imgui.NextColumn();
                imgui.Separator();

                for _, ph in ipairs(ph_list) do
                    local key   = string.format('ph:%d', ph.Id or 0);
                    local timer = gTracker.ActiveTimers[key];
                    local is_target = self.CurrentTargetId and
                        self.CurrentTargetId == ph.Id;

                    -- Check confirmation state
                    local confirmed = not gSettings.ph_confirmed or
                                      gSettings.ph_confirmed[ph.Id] ~= false;
                    local timer_expired = timer and gTracker:GetRemaining(timer) <= 0;
                    local unconfirmed = timer_expired and
                                        (not gSettings.ph_confirmed or
                                         gSettings.ph_confirmed[ph.Id] == nil);

                    if is_target then
                        imgui.TextColored(C.YELLOW, '> ' .. ph.Name);
                    elseif unconfirmed then
                        -- Greyed out: respawned but not yet targeted/confirmed
                        imgui.TextColored({ 0.45, 0.45, 0.45, 1.0 }, ph.Name .. ' (?)');
                    else
                        imgui.Text(ph.Name);
                    end
                    imgui.NextColumn();

                    imgui.TextColored(C.DIM, fmt_id(ph.Id));
                    imgui.NextColumn();

                    if timer then
                        local rem = gTracker:GetRemaining(timer);
                        if rem > 0 then
                            imgui.TextColored(C.RED, 'Dead');
                        elseif unconfirmed then
                            imgui.TextColored({ 0.55, 0.55, 0.55, 1.0 }, 'Unconfirmed');
                        else
                            imgui.TextColored(C.GREEN, 'Alive');
                        end
                    else
                        local alive_status = self:GetPHAliveStatus(ph.Id);
                        if alive_status == 'alive' then
                            imgui.TextColored(C.GREEN, 'Alive');
                        else
                            imgui.TextColored(C.DIM, 'Unknown');
                        end
                    end
                    imgui.NextColumn();

                    if timer then
                        local rem = gTracker:GetRemaining(timer);
                        if rem > 0 then
                            imgui.TextColored(C.YELLOW, fmt_time(rem));
                        else
                            imgui.TextColored(C.GREEN, 'Spawned');
                        end
                    else
                        -- No active timer: show the base respawn time dimmed as reference
                        imgui.TextColored(C.DIM, '~' .. fmt_time(ph.RespawnTime or 300));
                    end
                    imgui.NextColumn();

                    local chance = ph.Chance or nm.Chance or 0;
                    if chance > 0 then
                        imgui.TextColored(C.TLOTTO, string.format('%d%%', chance));
                    else
                        imgui.TextColored(C.DIM, '---');
                    end
                    imgui.NextColumn();
                end
                imgui.Columns(1);
            end
        end
    end
    self:_PopScale();
    imgui.End();
    imgui.PopStyleColor(4);
    gSettings.ph_detail_visible = self._detail_open[1];
    if not self._detail_open[1] then gSaveSettings(); end
end;

------------------------------------------------------------
-- Window 3: PH Popup (resizable, closes on target loss)
------------------------------------------------------------
gui.RenderPHPopup = function(self)
    if not self.PHPopupNM or self.PHPopupTimer <= 0 then return; end

    imgui.SetNextWindowSize({ 320, 140 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowPos({ 380, 380 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowBgAlpha(0.93);
    push_style(0.38, 0.08, 0.04, 0.80, 0.22, 0.08);

    if imgui.Begin('Eggs - Placeholder Detected##popup', self._popup_open, ImGuiWindowFlags_None) then
        imgui.Spacing();
        imgui.TextColored(C.YELLOW, '  Placeholder for:');
        imgui.SameLine();
        imgui.TextColored(C.GOLD, self.PHPopupNM);

        if self.PHPopupPHName then
            imgui.TextColored(C.DIM, '  PH: ' .. self.PHPopupPHName);
            imgui.SameLine();
            imgui.TextColored(C.DIM, '   ID: ' .. fmt_id(self.PHPopupMobId));
        end

        local nm = gNmData:GetNM(self.PHPopupNM) or gNmData:GetNMAnyZone(self.PHPopupNM);
        if nm then
            local info = nm_type_label(nm.NMType);
            if nm.NMType ~= 'timed_spawn' and (nm.Chance or 0) > 0 then
                info = info .. string.format(' (%d%% chance)', nm.Chance);
            end
            imgui.TextColored(nm_type_color(nm.NMType), '  ' .. info);
        end

        imgui.Spacing();
        imgui.Separator();
        imgui.Spacing();

        local is_tracked = (gSettings.tracked[self.PHPopupNM] ~= nil);
        if not is_tracked then
            imgui.PushStyleColor(ImGuiCol_Button, { 0.12, 0.32, 0.12, 1.0 });
            if imgui.Button('+ Track ' .. self.PHPopupNM .. '##ptrack') then
                gSettings.tracked[self.PHPopupNM] = { alarm = true };
                gSaveSettings();
            end
            imgui.PopStyleColor(1);
            imgui.SameLine();
        else
            imgui.TextColored(C.GREEN, '  Tracked');
            imgui.SameLine();
        end

        imgui.PushStyleColor(ImGuiCol_Button, { 0.10, 0.20, 0.38, 1.0 });
        if imgui.Button('PH Detail##pdetail') then
            self:SetDetailTarget(self.PHPopupNM);
            gSettings.ph_detail_visible = true;
            gSaveSettings();
        end
        imgui.PopStyleColor(1);
    end
    imgui.End();
    imgui.PopStyleColor(4);
    if not self._popup_open[1] then
        self.PHPopupNM = nil;
        self._popup_open[1] = true;
    end
end;

------------------------------------------------------------
-- Window 3b: NM Popup (shows when targeting a known NM)
------------------------------------------------------------
gui.RenderNMPopup = function(self)
    if not self.NMPopupName then return; end

    local nm = gNmData:GetNM(self.NMPopupName) or gNmData:GetNMAnyZone(self.NMPopupName);
    if not nm then return; end

    imgui.SetNextWindowSize({ 320, 140 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowPos({ 380, 530 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowBgAlpha(0.93);
    push_style(0.10, 0.04, 0.38, 0.80, 0.14, 0.08);

    if imgui.Begin('Eggs - NM Detected##nmpopup', self._nm_popup_open, ImGuiWindowFlags_None) then
        imgui.Spacing();
        imgui.TextColored(C.MAGENTA, '  NM is UP!');
        imgui.SameLine();
        imgui.TextColored(C.GOLD, self.NMPopupName);

        local info = nm_type_label(nm.NMType);
        if nm.NMType ~= 'timed_spawn' and (nm.Chance or 0) > 0 then
            info = info .. string.format(' (%d%% chance)', nm.Chance);
        end
        imgui.TextColored(nm_type_color(nm.NMType), '  ' .. info);

        imgui.Spacing();
        imgui.Separator();
        imgui.Spacing();

        local is_tracked = (gSettings.tracked and gSettings.tracked[nm.Name] ~= nil);
        if not is_tracked then
            imgui.PushStyleColor(ImGuiCol_Button, { 0.12, 0.32, 0.12, 1.0 });
            if imgui.Button('+ Track ' .. nm.Name .. '##nmtrack') then
                if not gSettings.tracked then gSettings.tracked = {}; end
                gSettings.tracked[nm.Name] = { alarm = true };
                gSaveSettings();
            end
            imgui.PopStyleColor(1);
            imgui.SameLine();
        else
            imgui.TextColored(C.GREEN, '  Tracked');
            imgui.SameLine();
        end

        imgui.PushStyleColor(ImGuiCol_Button, { 0.10, 0.20, 0.38, 1.0 });
        if imgui.Button('PH Detail##nmdetail') then
            self:SetDetailTarget(nm.Name);
            gSaveSettings();
        end
        imgui.PopStyleColor(1);
    end
    imgui.End();
    imgui.PopStyleColor(4);
    if not self._nm_popup_open[1] then
        self.NMPopupName       = nil;
        self._nm_popup_open[1] = true;
    end
end;

------------------------------------------------------------
------------------------------------------------------------
gui.RenderSettingsWindow = function(self)
    if not gSettings.settings_visible then return; end

    imgui.SetNextWindowSize({ 420, 460 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowPos({ gSettings.settings_pos[1], gSettings.settings_pos[2] }, ImGuiCond_FirstUseEver);
    push_style(0.08, 0.08, 0.08, 0.28, 0.28, 0.35);

    self._settings_open[1] = true;  -- ensure open flag is set before Begin
    if imgui.Begin('Eggs - Settings##settings', self._settings_open, ImGuiWindowFlags_None) then
        local p = { imgui.GetWindowPos() };
        gSettings.settings_pos = { p[1], p[2] };

        -- Sound picker
        imgui.TextColored(C.GOLD, 'Alarm Sound');
        imgui.Separator();
        for _, sd in ipairs(gSounds.Available) do
            if imgui.RadioButton(sd.label .. '##snd_' .. sd.id, gSettings.alarm_sound == sd.id) then
                gSettings.alarm_sound = sd.id; gSaveSettings();
            end
            imgui.SameLine();
            imgui.PushStyleColor(ImGuiCol_Button, { 0.16, 0.16, 0.20, 1.0 });
            if imgui.SmallButton('Test##t_' .. sd.id) then gSounds:Play(sd.id); end
            imgui.PopStyleColor(1);
        end

        imgui.Spacing();

        -- Alarm on/off
        imgui.TextColored(C.GOLD, 'Alarm');
        imgui.Separator();
        local alarm_on = { (gSettings.alarm_volume or 100) > 0 };
        if imgui.Checkbox('Alarm enabled', alarm_on) then
            gSettings.alarm_volume = alarm_on[1] and 100 or 0;
            gSaveSettings();
        end

        imgui.Spacing();

        -- Alarm triggers
        imgui.TextColored(C.GOLD, 'Alarm Triggers');
        imgui.Separator();
        local on_w = { gSettings.alarm_on_window };
        if imgui.Checkbox('Alarm when NM window opens / eligible', on_w) then
            gSettings.alarm_on_window = on_w[1]; gSaveSettings();
        end
        local on_p = { gSettings.alarm_on_ph_spawn };
        if imgui.Checkbox('Alarm when PH respawns', on_p) then
            gSettings.alarm_on_ph_spawn = on_p[1]; gSaveSettings();
        end
        local warn = { gSettings.alarm_warning_secs or 0 };
        imgui.PushItemWidth(200);
        if imgui.SliderInt('##warn', warn, 0, 600, 'Warn %d sec early') then
            gSettings.alarm_warning_secs = warn[1]; gSaveSettings();
        end
        imgui.PopItemWidth();

        imgui.Spacing();

        -- Display options
        imgui.TextColored(C.GOLD, 'Display Options');
        imgui.Separator();
        local sid = { gSettings.short_ids or false };
        if imgui.Checkbox('Show short IDs (last 3 digits only)', sid) then
            gSettings.short_ids = sid[1]; gSaveSettings();
        end

        local cu = { gSettings.confirm_untrack ~= false };
        if imgui.Checkbox('Confirm before removing tracked NM', cu) then
            gSettings.confirm_untrack = cu[1]; gSaveSettings();
        end

        -- Alive -> Unknown timeout
        local timeout_val = { gSettings.ph_alive_timeout or 60 };
        imgui.PushItemWidth(200);
        if imgui.SliderInt('##alivetimeout', timeout_val, 0, 300, 'Alive timeout: %d sec') then
            gSettings.ph_alive_timeout = timeout_val[1]; gSaveSettings();
        end
        imgui.PopItemWidth();
        imgui.TextColored(C.DIM, 'Time after targeting a PH before status shifts to Unknown. 0 = always Alive.');
        imgui.Spacing();

        local offset_val = { gSettings.despawn_offset or 10 };
        imgui.PushItemWidth(200);
        if imgui.SliderInt('##despawnoffset', offset_val, 0, 30, 'Despawn offset: %d sec') then
            gSettings.despawn_offset = offset_val[1]; gSaveSettings();
        end
        imgui.PopItemWidth();
        imgui.TextColored(C.DIM, 'Seconds added to auto-detected death time to account for body despawn delay.');

        -- UI Scale (like mobdb's Draw Scale - resizes all window content)
        local sc = { gSettings.ui_scale or 1.0 };
        imgui.PushItemWidth(200);
        if imgui.SliderFloat('##uiscale', sc, 0.5, 2.5, 'UI Scale: %.2f') then
            gSettings.ui_scale = sc[1];
            -- Reset col init so columns recalculate at new scale
            self._cols_init = false;
            self._detail_cols_init = false;
            gSaveSettings();
        end
        imgui.PopItemWidth();

        imgui.Spacing();

        -- Data
        imgui.TextColored(C.GOLD, 'Data');
        imgui.Separator();
        imgui.TextColored(C.DIM, 'Edit LSB_SERVER in addons/eggs/import.lua');
        imgui.PushStyleColor(ImGuiCol_Button, { 0.18, 0.28, 0.10, 1.0 });
        if imgui.Button('Run Import') then
            gSettings.settings_visible = false; gSaveSettings();
            local importer = require('import');
            importer:Run();
        end
        imgui.PopStyleColor(1);
        imgui.SameLine();
        imgui.PushStyleColor(ImGuiCol_Button, { 0.28, 0.10, 0.10, 1.0 });
        if imgui.Button('Clear All Timers') then
            gSettings.tod_data = {}; gTracker.ActiveTimers = T{}; gSaveSettings();
        end
        imgui.PopStyleColor(1);

        imgui.Spacing();
        imgui.TextColored(C.GOLD, 'Diagnostics');
        imgui.Separator();
        -- Lua heap is total VM memory, not per-addon, but useful for comparison
        local mem_kb = collectgarbage('count');
        local timer_count = 0; for _ in pairs(gTracker.ActiveTimers) do timer_count = timer_count + 1; end
        local cache_count = 0; if gTracker and gTracker.LastStatus then for _ in pairs(gTracker.LastStatus) do cache_count = cache_count + 1; end end
        imgui.TextColored(C.DIM, string.format('Lua heap: %.1f KB', mem_kb));
        imgui.TextColored(C.DIM, string.format('Active timers: %d   Entity cache: %d slots', timer_count, cache_count));
        imgui.TextColored(C.DIM, '(Lua heap is shared across all addons)');

        imgui.Spacing();
        imgui.TextColored(C.GOLD, 'Reset UI');
        imgui.Separator();
        imgui.TextColored(C.DIM, 'Resets all window positions and sizes.');
        imgui.PushStyleColor(ImGuiCol_Button, { 0.20, 0.20, 0.28, 1.0 });
        if imgui.Button('Reset All Windows') then
            gSettings.tracker_pos        = { 100, 100 };
            gSettings.ph_detail_pos      = { 400, 100 };
            gSettings.settings_pos       = { 200, 200 };
            gSettings.nm_browser_pos     = { 300, 150 };
            gGui._cols_init        = false;
            gGui._detail_cols_init = false;
            imgui.SetNextWindowPos({ 100, 100 }, ImGuiCond_Always);
            gSaveSettings();
            print(chat.header('Eggs') .. chat.message('UI positions reset.'));
        end
        imgui.PopStyleColor(1);
    end
    imgui.End();
    imgui.PopStyleColor(4);
    gSettings.settings_visible = self._settings_open[1];
    if not self._settings_open[1] then gSaveSettings(); end
end;

------------------------------------------------------------
-- Window 5: NM Browser
------------------------------------------------------------
gui.RenderBrowserWindow = function(self)
    if not gSettings.nm_browser_visible then return; end

    imgui.SetNextWindowSize({ 500, 540 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowPos({ gSettings.nm_browser_pos[1], gSettings.nm_browser_pos[2] }, ImGuiCond_FirstUseEver);
    push_style(0.05, 0.12, 0.05, 0.14, 0.52, 0.14);

    self._browser_open[1] = true;  -- ensure open flag is set before Begin
    if imgui.Begin('Eggs - NM Browser##browser', self._browser_open, ImGuiWindowFlags_None) then
        local p = { imgui.GetWindowPos() };
        gSettings.nm_browser_pos = { p[1], p[2] };

        if not gNmData.AllNMsLoaded then
            imgui.TextColored(C.YELLOW, 'No data loaded.');
            imgui.TextColored(C.DIM, 'Run /eggs import to generate zone data files.');
            imgui.PushStyleColor(ImGuiCol_Button, { 0.14, 0.28, 0.14, 1.0 });
            if imgui.Button('Load NM Data') then gNmData:LoadAllForBrowser(); end
            imgui.PopStyleColor(1);
        else
            -- Search
            imgui.TextColored(C.GOLD, 'Search:');
            imgui.SameLine();
            imgui.PushItemWidth(-1);
            imgui.InputText('##bsearch', self.BrowserSearch, 128);
            imgui.PopItemWidth();
            local sq = self.BrowserSearch[1]:lower();

            local tracked_count = 0;
            for _ in pairs(gSettings.tracked) do tracked_count = tracked_count + 1; end
            local fav_count = 0;
            if gSettings.favorites then
                for _ in pairs(gSettings.favorites) do fav_count = fav_count + 1; end
            end
            imgui.TextColored(C.DIM, string.format('%d NMs  |  Tracking: %d  |  Favorites: %d',
                #gNmData.AllNMs, tracked_count, fav_count));
            imgui.Separator();

            imgui.BeginChild('##nm_list');

            -- Tracked section
            local tracked = gSettings.tracked or {};
            local has_tracked = next(tracked) ~= nil;
            if has_tracked then
                imgui.PushStyleColor(ImGuiCol_Header,        { 0.20, 0.10, 0.35, 1.0 });
                imgui.PushStyleColor(ImGuiCol_HeaderHovered, { 0.26, 0.14, 0.44, 1.0 });
                local tracked_open = imgui.CollapsingHeader('Tracked##trackedzone');
                imgui.PopStyleColor(2);
                if tracked_open then
                    for nm_name, _ in pairs(tracked) do
                        local nm = gNmData:GetNMAnyZone(nm_name);
                        if nm then
                            self:RenderBrowserRow(nm, sq, false, 'tr_');
                        else
                            -- NM not in AllNMs (maybe wrong zone) - show basic row
                            imgui.TextColored(C.DIM, '  ' .. nm_name);
                            imgui.SameLine();
                            imgui.PushStyleColor(ImGuiCol_Button, { 0.45, 0.10, 0.10, 1.0 });
                            if imgui.SmallButton('X##brm_' .. nm_name) then
                                gSettings.tracked[nm_name] = nil;
                                gSaveSettings();
                            end
                            imgui.PopStyleColor(1);
                        end
                    end
                end
            end

            -- Favorites section
            local favs = gSettings.favorites or {};
            local has_favs = next(favs) ~= nil;
            if has_favs then
                imgui.PushStyleColor(ImGuiCol_Header,       { 0.20, 0.16, 0.04, 1.0 });
                imgui.PushStyleColor(ImGuiCol_HeaderHovered, { 0.28, 0.22, 0.06, 1.0 });
                local fav_open = imgui.CollapsingHeader('Favorites##favzone');
                imgui.PopStyleColor(2);
                if fav_open then
                    for _, nm in ipairs(gNmData.AllNMs) do
                        if favs[nm.Name] then
                            self:RenderBrowserRow(nm, sq, true);
                        end
                    end
                end
            end

            -- Zone-grouped list
            local cur_zone = '';
            for _, nm in ipairs(gNmData.AllNMs) do
                local match = sq == '' or
                    nm.Name:lower():find(sq, 1, true) or
                    nm.ZoneName:lower():find(sq, 1, true);
                if not match then goto cont_nm; end

                if nm.ZoneName ~= cur_zone then
                    cur_zone = nm.ZoneName;
                    if self.BrowserZones[cur_zone] == nil then
                        self.BrowserZones[cur_zone] = (sq ~= '');
                    end
                    imgui.PushStyleColor(ImGuiCol_Header,       { 0.08, 0.20, 0.08, 1.0 });
                    imgui.PushStyleColor(ImGuiCol_HeaderHovered, { 0.12, 0.28, 0.12, 1.0 });
                    local node_open = imgui.CollapsingHeader(
                        string.format('%s##zone_%s', cur_zone, cur_zone));
                    self.BrowserZones[cur_zone] = node_open;
                    imgui.PopStyleColor(2);
                end

                if self.BrowserZones[cur_zone] then
                    self:RenderBrowserRow(nm, sq, false);
                end

                ::cont_nm::
            end

            imgui.EndChild();
            imgui.Separator();
            imgui.TextColored(C.GREEN, string.format('Tracking %d NMs', tracked_count));

        end
    end
    imgui.End();
    imgui.PopStyleColor(4);
    gSettings.nm_browser_visible = self._browser_open[1];
    if not self._browser_open[1] then gSaveSettings(); end
end;

------------------------------------------------------------
-- Render a single NM row in the browser
------------------------------------------------------------
gui.RenderBrowserRow = function(self, nm, sq, is_fav_section, id_prefix)
    local favs = gSettings.favorites or {};
    local pfx = id_prefix or '';
    imgui.Indent(14);

    -- Track checkbox
    local is_tracked = (gSettings.tracked[nm.Name] ~= nil);
    local cb = { is_tracked };
    if imgui.Checkbox('##cb_' .. pfx .. nm.ZoneId .. '_' .. nm.Name, cb) then
        if cb[1] then
            gSettings.tracked[nm.Name] = { alarm = true, zone_id = nm.ZoneId };
            gSaveSettings();
        else
            if gSettings.confirm_untrack ~= false then
                gGui.ConfirmUntrack = nm.Name;
                cb[1] = true; -- revert visual until confirmed
            else
                gSettings.tracked[nm.Name] = nil;
                local del = {};
                for key, entry in pairs(gTracker.ActiveTimers) do
                    if entry.nm_name == nm.Name then del[#del+1] = key; end
                end
                for _, k in ipairs(del) do gTracker:RemoveTimer(k); end
                gSaveSettings();
            end
        end
    end
    imgui.SameLine();

    -- Star (favorites)
    local is_fav = favs[nm.Name] ~= nil;
    imgui.PushStyleColor(ImGuiCol_Button, {0,0,0,0});
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, {0.3,0.25,0.0,0.5});
    local star = is_fav and '[*]' or '[ ]';
    if imgui.SmallButton(star .. '##fav_' .. pfx .. nm.Name) then
        if not gSettings.favorites then gSettings.favorites = {}; end
        if is_fav then
            gSettings.favorites[nm.Name] = nil;
        else
            gSettings.favorites[nm.Name] = true;
        end
        gSaveSettings();
    end
    imgui.PopStyleColor(2);
    imgui.SameLine();

    -- NM name
    imgui.TextColored(is_tracked and C.GREEN or C.WHITE, nm.Name);
    imgui.SameLine();

    -- Type badge
    imgui.TextColored(nm_type_color(nm.NMType), ' [' .. nm_type_label(nm.NMType) .. ']');
    if nm.NMType ~= 'timed_spawn' and nm.Chance and nm.Chance > 0 then
        imgui.SameLine();
        imgui.TextColored(C.DIM, string.format(' %d%%', nm.Chance));
    end

    -- Window info for timed spawns
    if nm.NMType == 'timed_spawn' and nm.WindowMin and nm.WindowMin > 0 then
        imgui.SameLine();
        if nm.WindowMax and nm.WindowMax > nm.WindowMin then
            imgui.TextColored(C.DIM, string.format(' %s-%s', fmt_time(nm.WindowMin), fmt_time(nm.WindowMax)));
        else
            imgui.TextColored(C.DIM, ' ' .. fmt_time(nm.WindowMin));
        end
    end

    -- PH names + IDs
    if nm.PHs and #nm.PHs > 0 then
        local ph_strs = {};
        for _, ph in ipairs(nm.PHs) do
            ph_strs[#ph_strs+1] = ph.Name .. ' [' .. fmt_id(ph.Id) .. ']';
        end
        imgui.TextColored(C.DIM, '     PHs: ' .. table.concat(ph_strs, ', '));
    end

    imgui.Unindent(14);
end;

------------------------------------------------------------
-- Shared confirmation window for untracking
------------------------------------------------------------
gui.RenderConfirmUntrack = function(self)
    if not self.ConfirmUntrack then return; end
    imgui.SetNextWindowSize({ 320, 110 }, ImGuiCond_Appearing);
    local _open = { true };
    if imgui.Begin('Remove Tracking?##confirm', _open) then
        imgui.Text('Stop tracking ' .. self.ConfirmUntrack .. '?');
        imgui.TextColored(C.DIM, 'This will clear its saved ToD.');
        imgui.Spacing();
        imgui.PushStyleColor(ImGuiCol_Button, { 0.45, 0.10, 0.10, 1.0 });
        if imgui.Button('Remove', { 120, 0 }) then
            local nm_name = self.ConfirmUntrack;
            gSettings.tracked[nm_name] = nil;
            local del = {};
            for key, entry in pairs(gTracker.ActiveTimers) do
                if entry.nm_name == nm_name then del[#del+1] = key; end
            end
            for _, k in ipairs(del) do gTracker:RemoveTimer(k); end
            gSaveSettings();
            self.ConfirmUntrack = nil;
        end
        imgui.PopStyleColor(1);
        imgui.SameLine();
        if imgui.Button('Cancel', { 120, 0 }) then
            self.ConfirmUntrack = nil;
        end
    end
    imgui.End();
    if not _open[1] then self.ConfirmUntrack = nil; end
end;

------------------------------------------------------------
-- Window 5b: Loot Window
------------------------------------------------------------
gui.RenderLootWindow = function(self)
    if not self.LootTarget or not self.LootVisible then return; end

    local nm = gNmData:GetNM(self.LootTarget) or gNmData:GetNMAnyZone(self.LootTarget);
    if not nm or not nm.Loot or #nm.Loot == 0 then
        self.LootTarget  = nil;
        self.LootVisible = false;
        return;
    end

    local TYPE_LABEL = { [0]='Drop', [1]='Drop', [2]='Steal', [4]='Despoil' };
    local open = { true };

    imgui.SetNextWindowSize({ 400, 280 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowPos({ 500, 200 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowBgAlpha(0.95);
    push_style(0.10, 0.07, 0.02, 0.55, 0.40, 0.05);

    local title = 'Loot: ' .. self.LootTarget .. '##lootwin';
    if imgui.Begin(title, open, ImGuiWindowFlags_None) then
        self:_ApplyScale();

        imgui.Columns(3, 'loot_cols', true);
        do
            local sc = gSettings.ui_scale or 1.0;
            imgui.SetColumnWidth(0, math.floor(180 * sc));
            imgui.SetColumnWidth(1, math.floor(70  * sc));
            imgui.SetColumnWidth(2, math.floor(110 * sc));
        end
        imgui.TextColored(C.GOLD, 'Item');      imgui.NextColumn();
        imgui.TextColored(C.GOLD, 'Chance');    imgui.NextColumn();
        imgui.TextColored(C.GOLD, 'Type');      imgui.NextColumn();
        imgui.Separator();

        -- Sort: standalone drops first, then group drops by group number
        local sorted = {};
        for _, d in ipairs(nm.Loot) do sorted[#sorted+1] = d; end
        table.sort(sorted, function(a, b)
            local at = a.Type == 0 and 0 or (a.Type == 1 and 1 or 2);
            local bt = b.Type == 0 and 0 or (b.Type == 1 and 1 or 2);
            if at ~= bt then return at < bt; end
            if a.GroupId ~= b.GroupId then return (a.GroupId or 0) < (b.GroupId or 0); end
            return (b.Rate or 0) < (a.Rate or 0);
        end);

        for _, drop in ipairs(sorted) do
            local pct      = drop.Rate / 10.0;
            local rate_str = string.format('%.1f%%', pct);
            local type_str;
            if drop.Type == 1 then
                local gpct = math.floor((drop.GroupRate or 1000) / 10);
                type_str = string.format('Group %d (%d%%)', drop.GroupId or 0, gpct);
            elseif drop.Type == 2 then
                type_str = 'Steal';
            elseif drop.Type == 4 then
                type_str = 'Despoil';
            else
                type_str = 'Drop';
            end

            if drop.Type == 2 then
                imgui.TextColored(C.YELLOW, drop.Name);
            elseif drop.Type == 4 then
                imgui.TextColored({ 0.70, 0.40, 0.95, 1.0 }, drop.Name);
            else
                imgui.Text(drop.Name);
            end
            imgui.NextColumn();

            if drop.Rate >= 1000 then
                imgui.TextColored(C.OPEN,   rate_str);
            elseif drop.Rate >= 150 then
                imgui.TextColored(C.GREEN,  rate_str);
            elseif drop.Rate >= 50 then
                imgui.TextColored(C.YELLOW, rate_str);
            else
                imgui.TextColored(C.RED,    rate_str);
            end
            imgui.NextColumn();

            imgui.TextColored(C.DIM, type_str);
            imgui.NextColumn();
        end

        imgui.Columns(1);
    end
    self:_PopScale();
    imgui.End();
    imgui.PopStyleColor(4);

    if not open[1] then
        self.LootTarget  = nil;
        self.LootVisible = false;
    end
end;

------------------------------------------------------------
------------------------------------------------------------
gui.Render = function(self)
    gTracker:Tick();
    self:RenderTrackerWindow();
    self:RenderDetailWindow();
    self:RenderPHPopup();
    self:RenderNMPopup();
    self:RenderLootWindow();
    self:RenderSettingsWindow();
    self:RenderBrowserWindow();
    self:RenderConfirmUntrack();
end;

-- Apply scale: called inside each window after Begin() succeeds
gui._ApplyScale = function(self)
    local scale = gSettings.ui_scale or 1.0;
    imgui.PushFont(nil, 13 * scale);
    -- Scale column widths proportionally
    if self._last_scale ~= scale then
        self._last_scale = scale;
        self._cols_init = false;
        self._detail_cols_init = false;
    end
end;

gui._PopScale = function(self)
    imgui.PopFont();
end;

return gui;
