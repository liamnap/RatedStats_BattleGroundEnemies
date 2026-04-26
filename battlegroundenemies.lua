local addonName, RSTATS = ...
RSTATS = RSTATS or _G.RSTATS

-- Rated Stats - Battleground Enemies
-- 12.0.5 nameplate-only rebuild.
-- No scoreboard seeding, no GetBattlefieldScore, no C_PvP.GetScoreInfo.
-- Stable roster slots are filled from exposed enemy nameplate units.
-- Name/spec/role are not taken from secret scoreboard fields or enemy inspection.
-- Live rows use exposed nameplate identity, class colour, health, power, OOR, dead state, and achievements.

local BGE = {}
_G.RSTATS_BGE = BGE

BGE.rows = {}
BGE.previewRows = {}
BGE.maxPlates = 40
BGE.expectedRows = 10

BGE.rowByUnit = {}
BGE.rowByGuid = {}
BGE.rowByDisplayName = {}
BGE.rowByBaseName = {}
BGE._dbgLast = {}
BGE._enteredBGAt = nil
BGE._oorEnabled = false
BGE._matchStarted = false
BGE._anchorsDirty = false
BGE._rowsDirty = false
BGE._showDirty = false
BGE._profilePrefix = nil
BGE._selectedRow = nil
BGE._anchorHover = 0
BGE._anchorHidePending = false
BGE._dropdownMenu = nil
BGE._menuOpen = false

local RS_TEXT_R, RS_TEXT_G, RS_TEXT_B = 182/255, 158/255, 134/255

local ROW_ALPHA_ACTIVE   = 1.0
local ROW_ALPHA_OOR      = 0.55
local ROW_ALPHA_DEAD     = 0.50
local ROW_ALPHA_UNKNOWN  = 0.35
local CLASS_ALPHA_ACTIVE = 1.00
local CLASS_ALPHA_OOR    = 0.55
local CLASS_ALPHA_DEAD   = 0.50

local GetSetting
local SetSetting
local CreateMainFrame
local UpdateNameClipToHPFill

local function InLockdown()
    return _G.InCombatLockdown and _G.InCombatLockdown()
end

local function SafeToString(v)
    local ok, s = pcall(function() return tostring(v) end)
    if not ok or type(s) ~= "string" then return nil end
    if _G.issecretvalue and _G.issecretvalue(s) then return nil end
    return s
end

local function SafeNonEmptyString(v)
    local s = SafeToString(v)
    if type(s) ~= "string" then return nil end
    local okLen, n = pcall(string.len, s)
    if not okLen or n == 0 then return nil end
    return s
end

local function SafeNumber(v)
    if type(v) ~= "number" then return nil end
    if _G.issecretvalue and _G.issecretvalue(v) then return nil end
    return v
end

local function Bool01(v)
    return v and "1" or "0"
end

local function SafeBool(v)
    if _G.scrubsecretvalues then
        local ok, clean = pcall(_G.scrubsecretvalues, v)
        if ok then v = clean end
    end
    if _G.issecretvalue and _G.issecretvalue(v) then return false end
    return v == true
end


local function IsNameplateUnit(unit)
    return type(unit) == "string" and unit:match("^nameplate%d+$") ~= nil
end

local function NameplateIndex(unit)
    if type(unit) ~= "string" then return nil end
    local n = unit:match("^nameplate(%d+)$")
    n = n and tonumber(n) or nil
    if not n or n < 1 then return nil end
    return n
end

local function NameplateUnitFromIndex(i)
    return "nameplate" .. tostring(i)
end

local function IsInPVPInstance()
    if _G.IsInInstance then
        local ok, inInstance, instanceType = pcall(_G.IsInInstance)
        if ok and inInstance then
            return instanceType == "pvp"
        end
    end
    if C_PvP and C_PvP.IsPVPMap then
        local ok, v = pcall(C_PvP.IsPVPMap)
        return ok and v or false
    end
    return false
end

local function DPrint(key, msg)
    if not GetSetting or not GetSetting("bgeDebug", false) then return end
    local now = GetTime()
    local last = BGE._dbgLast[key] or 0
    if (now - last) < 1.0 then return end
    BGE._dbgLast[key] = now
    print("|cffb69e86[RSTATS-BGE]|r " .. msg)
end

local function SafeUnitExists(unit)
    if not unit then return false end
    local ok, exists = pcall(UnitExists, unit)
    return ok and SafeBool(exists)
end

local function SafeUnitIsFriend(unit)
    if not unit then return false end
    local ok, friendly = pcall(UnitIsFriend, "player", unit)
    return ok and SafeBool(friendly)
end

local function SafeUnitIsEnemy(unit)
    if not SafeUnitExists(unit) then return false end
    if SafeUnitIsFriend(unit) then return false end
    if _G.UnitIsEnemy then
        local ok, enemy = pcall(UnitIsEnemy, "player", unit)
        if ok and SafeBool(enemy) then return true end
    end
    return false
end

local function SafeUnitIsDead(unit)
    if not SafeUnitExists(unit) then return false end
    if not _G.UnitIsDeadOrGhost then return false end
    local ok, dead = pcall(UnitIsDeadOrGhost, unit)
    return ok and SafeBool(dead)
end

local function SafeUnitGUID(unit)
    if not unit then return nil end
    local ok, guid = pcall(UnitGUID, unit)
    if not ok then return nil end
    return SafeNonEmptyString(guid)
end

local function SafeUnitName(unit)
    if not unit then return nil, nil end
    local ok, name, realm = pcall(UnitName, unit)
    if not ok then return nil, nil end
    local n = SafeNonEmptyString(name)
    if not n then return nil, nil end
    local r = SafeNonEmptyString(realm)
    return n, r
end

local function SafeUnitFullName(unit)
    local n, r = SafeUnitName(unit)
    if not n then return nil, nil end
    if r then return n .. "-" .. r, n end
    return n, n
end

local function SafeUnitClass(unit)
    if not unit then return nil, nil, nil end

    if _G.UnitClassBase then
        local okBase, classFileBase, classIDBase = pcall(_G.UnitClassBase, unit)
        local classFile = okBase and SafeNonEmptyString(classFileBase) or nil
        local classID = okBase and tonumber(SafeToString(classIDBase)) or nil
        if classFile then
            return nil, classFile, classID
        end
    end

    if _G.UnitClass then
        local ok, localized, classFile, classID = pcall(_G.UnitClass, unit)
        if ok then
            return SafeNonEmptyString(localized), SafeNonEmptyString(classFile), tonumber(SafeToString(classID))
        end
    end

    return nil, nil, nil
end

local function NormalizeFactionIndex(v)
    local s = SafeToString(v)
    if type(s) ~= "string" then return nil end
    local n = tonumber(s)
    if n == 0 or n == 1 then return n end
    if s == "Alliance" then return 1 end
    if s == "Horde" then return 0 end
    return nil
end

local function GetUnitTrueFactionIndex(unit)
    local fac = UnitFactionGroup and UnitFactionGroup(unit) or nil
    local idx = NormalizeFactionIndex(fac)
    if UnitIsMercenary and UnitIsMercenary(unit) then
        idx = (idx == 0 and 1) or 0
    end
    return idx
end

local function SafePlateFrame(unit)
    if not (_G.C_NamePlate and _G.C_NamePlate.GetNamePlateForUnit) then return nil, nil end
    local ok, plate = pcall(_G.C_NamePlate.GetNamePlateForUnit, unit)
    if not ok or not plate then return nil, nil end
    return plate, plate.UnitFrame
end

local function GetNameplateDisplayNames(unit)
    local _, uf = SafePlateFrame(unit)
    if not uf then return nil, nil end

    local disp = nil
    local function TryFS(fs)
        if disp then return end
        if not fs or not fs.GetText then return end
        local okT, t = pcall(fs.GetText, fs)
        local s = SafeNonEmptyString(t)
        if s then disp = s end
    end

    TryFS(uf.name)
    TryFS(uf.Name)
    TryFS(uf.unitName)
    TryFS(uf.UnitName)

    if uf.healthBar then
        TryFS(uf.healthBar.name)
        TryFS(uf.healthBar.unitName)
        TryFS(uf.healthBar.UnitName)
        TryFS(uf.healthBar.TextString)
    end
    if uf.HealthBar then
        TryFS(uf.HealthBar.name)
        TryFS(uf.HealthBar.unitName)
        TryFS(uf.HealthBar.UnitName)
        TryFS(uf.HealthBar.TextString)
    end

    if not disp and uf.GetRegions then
        local regions = { uf:GetRegions() }
        for i = 1, #regions do
            local r = regions[i]
            if r and r.GetObjectType then
                local okOT, ot = pcall(r.GetObjectType, r)
                if okOT and ot == "FontString" then
                    TryFS(r)
                    if disp then break end
                end
            end
        end
    end

    if not disp then
        local full, base = SafeUnitFullName(unit)
        disp = full
        if not base and disp then
            local okB, b = pcall(function() return disp:match("^[^-]+") end)
            base = (okB and b) or disp
        end
        return disp, base
    end

    local okB, base = pcall(function() return disp:match("^[^-]+") end)
    return disp, (okB and base) or disp
end

local function SafeStatusBarValues(sb)
    if not sb or not sb.GetValue or not sb.GetMinMaxValues then return nil, nil end
    local okV, v = pcall(sb.GetValue, sb)
    local okMM, mn, mx = pcall(sb.GetMinMaxValues, sb)
    if not okV or not okMM then return nil, nil end
    v = SafeNumber(v)
    mx = SafeNumber(mx)
    if not v or not mx or mx <= 0 then return nil, nil end
    return v, mx
end

local function FindStatusBar(parent, skip)
    if not (parent and parent.GetChildren) then return nil end
    local kids = { parent:GetChildren() }
    for i = 1, #kids do
        local k = kids[i]
        if k and k.GetObjectType then
            local okOT, ot = pcall(k.GetObjectType, k)
            if okOT and ot == "StatusBar" and k ~= skip then
                local cur, maxv = SafeStatusBarValues(k)
                if cur and maxv then return k end
            end
        end
    end
    return nil
end

local function FindPlateHealthStatusBar(unit)
    local _, uf = SafePlateFrame(unit)
    if not uf then return nil end
    local candidates = {
        uf.healthBar,
        uf.HealthBar,
        (uf.HealthBarsContainer and uf.HealthBarsContainer.healthBar),
        (uf.healthBar and uf.healthBar.bar),
        (uf.healthBar and uf.healthBar.healthBar),
    }
    for i = 1, #candidates do
        local sb = candidates[i]
        local cur, maxv = SafeStatusBarValues(sb)
        if cur and maxv then return sb end
    end
    return FindStatusBar(uf)
end

local function FindPlatePowerStatusBar(unit)
    local _, uf = SafePlateFrame(unit)
    if not uf then return nil end
    local candidates = {
        uf.manabar,
        uf.manaBar,
        uf.powerBar,
        uf.PowerBar,
        (uf.PowerBarsContainer and uf.PowerBarsContainer.powerBar),
        (uf.manabar and uf.manabar.bar),
        (uf.powerBar and uf.powerBar.bar),
    }
    for i = 1, #candidates do
        local sb = candidates[i]
        local cur, maxv = SafeStatusBarValues(sb)
        if cur and maxv then return sb end
    end
    local sb = FindStatusBar(uf.PowerBarsContainer)
    if sb then return sb end
    return FindStatusBar(uf, uf.healthBar or uf.HealthBar)
end

local function SafePercentFromStatusBarFill(sb)
    if not sb or not sb.GetWidth or not sb.GetStatusBarTexture then return nil end
    local okW, w = pcall(sb.GetWidth, sb)
    w = okW and SafeNumber(w) or nil
    if not w or w <= 0 then return nil end

    local okTex, tex = pcall(sb.GetStatusBarTexture, sb)
    if not okTex or not tex or not tex.GetWidth then return nil end
    local okTW, tw = pcall(tex.GetWidth, tex)
    tw = okTW and SafeNumber(tw) or nil
    if not tw then return nil end

    local okP, pct = pcall(function() return math.floor((tw / w) * 100 + 0.5) end)
    if not okP or type(pct) ~= "number" then return nil end
    if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
    return pct
end

local function SafePlateHealthNumericText(sb)
    if not sb then return nil end
    local fs = sb.TextString or sb.Text or sb.RightText or sb.LeftText
    if not fs or not fs.GetText then return nil end
    local okT, t = pcall(fs.GetText, fs)
    if not okT then return nil end
    return SafeNonEmptyString(t)
end

local function ColorFromStatusBar(sb, fallbackR, fallbackG, fallbackB)
    local r, g, b = fallbackR or 0, fallbackG or 0.55, fallbackB or 1
    if sb and sb.GetStatusBarColor then
        local ok, cr, cg, cb = pcall(sb.GetStatusBarColor, sb)
        cr, cg, cb = SafeNumber(cr), SafeNumber(cg), SafeNumber(cb)
        if ok and cr and cg and cb then
            r, g, b = cr, cg, cb
        end
    end
    return r, g, b
end

local function GetClassRGB(classFile)
    if classFile then
        if C_ClassColor and C_ClassColor.GetClassColor then
            local ok, c = pcall(C_ClassColor.GetClassColor, classFile)
            if ok and c and c.GetRGB then
                local r, g, b = c:GetRGB()
                if type(r) == "number" then return r, g, b end
            end
        end
        if RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
            local c = RAID_CLASS_COLORS[classFile]
            return c.r, c.g, c.b
        end
    end
    return 0.10, 0.90, 0.10
end

local function ApplyClassAlpha(row, a)
    if not row or not row.hp then return end
    local r, g, b = GetClassRGB(row.classFile)
    row.hp:SetStatusBarColor(r, g, b, a or CLASS_ALPHA_ACTIVE)
end

local function FormatHealthText(cur, maxv, mode)
    cur, maxv = SafeNumber(cur), SafeNumber(maxv)
    if not cur or not maxv or maxv <= 0 then return nil end
    if mode == 2 then
        return tostring(math.floor(cur + 0.5)) .. "/" .. tostring(math.floor(maxv + 0.5))
    elseif mode == 3 then
        return tostring(math.floor((cur / maxv) * 100 + 0.5)) .. "%"
    end
    return tostring(math.floor(cur + 0.5))
end

local function NormalizeRole(role)
    local s = SafeNonEmptyString(role)
    if not s then return nil end
    s = s:upper()
    if s == "TANK" or s == "HEALER" or s == "DAMAGER" then return s end
    return nil
end

local function SetRoleTexture(tex, role)
    if not tex then return false end
    role = NormalizeRole(role)
    if not role then
        tex:Hide()
        return false
    end
    if tex.SetAtlas and _G.GetMicroIconForRole then
        local okAtlas, atlas = pcall(_G.GetMicroIconForRole, role)
        if okAtlas and type(atlas) == "string" then
            local okSet = pcall(tex.SetAtlas, tex, atlas, true)
            if okSet then
                tex:SetTexCoord(0, 1, 0, 1)
                tex:Show()
                return true
            end
        end
    end
    tex:Hide()
    return false
end

local function GetPlayerDB()
    if type(_G.LoadData) == "function" then
        pcall(_G.LoadData)
    end
    local RS = _G.RSTATS
    if not RS or not RS.Database then return nil end
    local n = UnitName("player")
    local r = GetRealmName and GetRealmName() or nil
    if not n or not r then return nil end
    local key = n .. "-" .. r
    local db = RS.Database[key]
    if not db then return nil end
    db.settings = db.settings or {}
    return db
end

local BGE_PROFILE_SUFFIX = {
    bgePreview       = "Preview",
    bgePreviewCount  = "PreviewCount",
    bgeColumns       = "Columns",
    bgeRowsPerCol    = "RowsPerCol",
    bgeColGap        = "ColGap",
    bgeRowWidth      = "RowWidth",
    bgeRowHeight     = "RowHeight",
    bgeRowGap        = "RowGap",
}

local function ResolvePreviewProfilePrefix(db)
    if not db or not db.settings then return "bgeRated" end
    local s = db.settings
    if s.bgeRatedPreview then return "bgeRated" end
    if s.bge10Preview then return "bge10" end
    if s.bge15Preview then return "bge15" end
    if s.bgeLargePreview then return "bgeLarge" end
    return "bgeRated"
end

local function ResolveLiveProfilePrefix()
    local isSoloRBG = false
    local isRatedBG = false

    if C_PvP and C_PvP.IsRatedSoloRBG then
        local ok, v = pcall(C_PvP.IsRatedSoloRBG)
        isSoloRBG = ok and SafeBool(v)
    end
    if (not isSoloRBG) and C_PvP and C_PvP.IsSoloRBG then
        local ok, v = pcall(C_PvP.IsSoloRBG)
        isSoloRBG = ok and SafeBool(v)
    end
    if (not isSoloRBG) and C_PvP and C_PvP.IsRatedBattleground then
        local ok, v = pcall(C_PvP.IsRatedBattleground)
        isRatedBG = ok and SafeBool(v)
    elseif (not isSoloRBG) and _G.IsRatedBattleground then
        local ok, v = pcall(_G.IsRatedBattleground)
        isRatedBG = ok and SafeBool(v)
    end

    if isSoloRBG then return "bgeRated", 8 end
    if isRatedBG then return "bge10", 10 end

    local maxPlayers = nil
    if _G.GetInstanceInfo then
        local ok, _, instType, _, _, instMaxPlayers = pcall(_G.GetInstanceInfo)
        if ok and instType == "pvp" and type(instMaxPlayers) == "number" and instMaxPlayers > 0 then
            maxPlayers = instMaxPlayers
        end
    end

    if maxPlayers and maxPlayers > 15 then return "bgeLarge", math.min(maxPlayers, 40) end
    if maxPlayers == 15 then return "bge15", 15 end
    return "bge10", 10
end

GetSetting = function(key, default)
    local db = GetPlayerDB()
    if not db then return default end

    local suffix = BGE_PROFILE_SUFFIX[key]
    if suffix then
        if key == "bgePreview" and IsInPVPInstance() then
            return false
        end

        local prefix = BGE._profilePrefix
        if not IsInPVPInstance() then
            prefix = ResolvePreviewProfilePrefix(db)
            BGE._profilePrefix = prefix
        end

        if prefix then
            local v2 = db.settings[prefix .. suffix]
            if v2 ~= nil then return v2 end
        end

        local vLegacy = db.settings[key]
        if vLegacy ~= nil then return vLegacy end
        return default
    end

    local v = db.settings[key]
    if v == nil then return default end
    return v
end

SetSetting = function(key, value)
    local db = GetPlayerDB()
    if not db then return end
    db.settings[key] = value
end

local function GetEnemyFactionIndex()
    if _G.C_PvP and _G.C_PvP.GetActiveMatchFaction then
        local okF, f = pcall(_G.C_PvP.GetActiveMatchFaction)
        local myIdx = okF and NormalizeFactionIndex(f) or nil
        if myIdx ~= nil then return (myIdx == 0 and 1) or 0 end
    end
    if _G.GetBattlefieldArenaFaction then
        local ok, fi = pcall(_G.GetBattlefieldArenaFaction)
        if ok and type(fi) == "number" then return (fi + 1) % 2 end
    end
    local myIdx = GetUnitTrueFactionIndex("player")
    return (myIdx == 0 and 1) or 0
end

function BGE:GetEnemyTeamColorRGB()
    local enemyFactionIndex = GetEnemyFactionIndex()
    if _G.PVPMatchStyle and _G.PVPMatchStyle.GetTeamColor then
        local ok, c = pcall(_G.PVPMatchStyle.GetTeamColor, enemyFactionIndex, false)
        if ok and c and c.GetRGBA then
            local r, g, b = c:GetRGBA()
            if type(r) == "number" then return r, g, b end
        end
    end
    if enemyFactionIndex == 0 then
        return 1.0, 0.08, 0.08
    end
    return 0.08, 0.45, 1.0
end

function BGE:UpdateFrameTeamTint()
    if not self.frame or not self.frame.bg then return end

    if GetSetting("bgePreview", false) then
        local fac = UnitFactionGroup and UnitFactionGroup("player") or nil
        if fac == "Horde" then
            self.frame.bg:SetColorTexture(0.08, 0.45, 1.0, 0.20)
        else
            self.frame.bg:SetColorTexture(1.0, 0.08, 0.08, 0.20)
        end
        return
    end

    if not IsInPVPInstance() then
        self.frame.bg:SetColorTexture(0, 0, 0, 0)
        return
    end

    local r, g, b = self:GetEnemyTeamColorRGB()
    self.frame.bg:SetColorTexture(r, g, b, 0.14)
end

function BGE:AnchorHoverBegin()
    self._anchorHover = (self._anchorHover or 0) + 1
    if self.frame and self.frame.anchorTab then
        self.frame.anchorTab:Show()
    end
end

function BGE:AnchorHoverEnd()
    self._anchorHover = (self._anchorHover or 0) - 1
    if self._anchorHover < 0 then self._anchorHover = 0 end
    if self._anchorHover > 0 or self._menuOpen or self._anchorHidePending then return end

    self._anchorHidePending = true
    if C_Timer and C_Timer.After then
        C_Timer.After(0.15, function()
            local bge = _G.RSTATS_BGE
            if not bge then return end
            bge._anchorHidePending = false
            if (bge._anchorHover or 0) == 0 and not bge._menuOpen and bge.frame and bge.frame.anchorTab then
                bge.frame.anchorTab:Hide()
            end
        end)
    else
        self._anchorHidePending = false
        if self.frame and self.frame.anchorTab then self.frame.anchorTab:Hide() end
    end
end

function BGE:OpenRatedStatsSettings()
    if type(_G.RSTATS_OpenSettings) == "function" then
        pcall(_G.RSTATS_OpenSettings)
        return
    end
    if _G.RSTATS and type(_G.RSTATS.OpenSettings) == "function" then
        pcall(_G.RSTATS.OpenSettings, _G.RSTATS)
        return
    end
    if _G.Settings and type(_G.Settings.GetCategory) == "function" and type(_G.Settings.OpenToCategory) == "function" then
        local cat = nil
        local ok1, c1 = pcall(_G.Settings.GetCategory, "Rated Stats")
        if ok1 then cat = c1 end
        if not cat then
            local ok2, c2 = pcall(_G.Settings.GetCategory, "RatedStats")
            if ok2 then cat = c2 end
        end
        if cat and cat.GetID then
            local okID, id = pcall(cat.GetID, cat)
            if okID and type(id) == "number" then
                pcall(_G.Settings.OpenToCategory, id)
                return
            end
        end
    end
    if _G.C_SettingsUtil and _G.C_SettingsUtil.OpenSettingsPanel then
        pcall(_G.C_SettingsUtil.OpenSettingsPanel)
    elseif _G.InterfaceOptionsFrame_OpenToCategory then
        pcall(_G.InterfaceOptionsFrame_OpenToCategory, "AddOns")
    end
end

function BGE:ShowAnchorMenu(owner)
    if not owner then return end

    local function ToggleLock()
        local locked = GetSetting("bgeLocked", true)
        SetSetting("bgeLocked", not locked)
        if _G.RSTATS_BGE and _G.RSTATS_BGE.ApplySettings then
            _G.RSTATS_BGE:ApplySettings()
        end
    end

    self._menuOpen = true
    self:AnchorHoverBegin()

    local function ReleaseMenuHold()
        local bge = _G.RSTATS_BGE
        if not bge then return end
        bge._menuOpen = false
        bge:AnchorHoverEnd()
    end

    if _G.MenuUtil and type(_G.MenuUtil.CreateContextMenu) == "function" then
        local menu = _G.MenuUtil.CreateContextMenu(owner, function(_, root)
            root:CreateTitle("Rated Stats - BGE")
            root:CreateCheckbox("Lock", function() return GetSetting("bgeLocked", true) end, ToggleLock)
            root:CreateButton("Settings", function() self:OpenRatedStatsSettings() end)
        end)
        if menu and menu.HookScript then
            menu:HookScript("OnHide", ReleaseMenuHold)
        else
            ReleaseMenuHold()
        end
        return
    end

    if not _G.EasyMenu then return end
    if not self._dropdownMenu then
        self._dropdownMenu = CreateFrame("Frame", "RatedStats_BGE_Dropdown", UIParent, "UIDropDownMenuTemplate")
    end
    local menu = {
        { text = "Rated Stats - BGE", isTitle = true, notCheckable = true },
        { text = "Lock", isNotRadio = true, keepShownOnClick = true, checked = GetSetting("bgeLocked", true), func = ToggleLock },
        { text = "Settings", notCheckable = true, func = function() self:OpenRatedStatsSettings() end },
    }
    _G.EasyMenu(menu, self._dropdownMenu, owner, 0, 0, "MENU")
    if _G.DropDownList1 and _G.DropDownList1.HookScript then
        _G.DropDownList1:HookScript("OnHide", ReleaseMenuHold)
    else
        ReleaseMenuHold()
    end
end

local __achievWarnedMissingAPI = false

local function GetIconTextureForEnemyName(fullName, baseName)
    if not GetSetting("bgeShowAchievIcon", false) then return nil end
    local fn = SafeNonEmptyString(fullName)
    local bn = SafeNonEmptyString(baseName)
    if not fn and not bn then return nil end

    local api = (type(_G.RSTATS_Achiev_GetHighestPvpRank) == "function") and _G.RSTATS_Achiev_GetHighestPvpRank or nil
    if not api then
        if not __achievWarnedMissingAPI then
            __achievWarnedMissingAPI = true
            print("|cffb69e86[RSTATS-BGE]|r Achievements icon enabled but no Achievements lookup API found (expected RSTATS_Achiev_GetHighestPvpRank).")
        end
        return nil
    end

    if fn then
        local ok, iconPath, highestText, iconTint = pcall(api, fn)
        if ok and type(iconPath) == "string" and iconPath ~= "" then return iconPath, highestText, iconTint end
    end
    if bn then
        local ok, iconPath, highestText, iconTint = pcall(api, bn)
        if ok and type(iconPath) == "string" and iconPath ~= "" then return iconPath, highestText, iconTint end
    end
    return nil
end

local function MakeRow(parent, index)
    local row = CreateFrame("Button", nil, parent, "SecureActionButtonTemplate")
    row:SetAlpha(0)
    row:Show()
    row:EnableMouse(true)
    row:RegisterForClicks(GetCVarBool("ActionButtonUseKeyDown") and "AnyDown" or "AnyUp")
    row:SetAttribute("type1", "target")
    row:SetAttribute("unit", nil)
    row.plateIndex = nil
    row.unit = nil
    row._secureUnit = nil

    row:SetScript("PostClick", function(self)
        local bge = _G.RSTATS_BGE
        if bge then bge:SetSelectedRow(self) end
    end)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints(true)
    row.bg:SetColorTexture(0, 0, 0, 0.35)

    row.borderTop = row:CreateTexture(nil, "BORDER")
    row.borderTop:SetColorTexture(0, 0, 0, 0.8)
    row.borderBottom = row:CreateTexture(nil, "BORDER")
    row.borderBottom:SetColorTexture(0, 0, 0, 0.8)
    row.borderLeft = row:CreateTexture(nil, "BORDER")
    row.borderLeft:SetColorTexture(0, 0, 0, 0.8)
    row.borderRight = row:CreateTexture(nil, "BORDER")
    row.borderRight:SetColorTexture(0, 0, 0, 0.8)

    row.selectTop = row:CreateTexture(nil, "OVERLAY")
    row.selectTop:SetColorTexture(1, 1, 1, 0.9)
    row.selectTop:SetHeight(1)
    row.selectTop:Hide()
    row.selectBottom = row:CreateTexture(nil, "OVERLAY")
    row.selectBottom:SetColorTexture(1, 1, 1, 0.9)
    row.selectBottom:SetHeight(1)
    row.selectBottom:Hide()
    row.selectLeft = row:CreateTexture(nil, "OVERLAY")
    row.selectLeft:SetColorTexture(1, 1, 1, 0.9)
    row.selectLeft:SetWidth(1)
    row.selectLeft:Hide()
    row.selectRight = row:CreateTexture(nil, "OVERLAY")
    row.selectRight:SetColorTexture(1, 1, 1, 0.9)
    row.selectRight:SetWidth(1)
    row.selectRight:Hide()

    row.hp = CreateFrame("StatusBar", nil, row)
    row.hp:SetMinMaxValues(0, 1)
    row.hp:SetValue(0)
    row.hp:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")

    row.power = CreateFrame("StatusBar", nil, row)
    row.power:SetMinMaxValues(0, 1)
    row.power:SetValue(0)
    row.power:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    row.power:Hide()

    row.roleIcon = row.hp:CreateTexture(nil, "OVERLAY")
    row.roleIcon:SetTexCoord(0, 1, 0, 1)
    row.roleIcon:Hide()

    row.icon = row.hp:CreateTexture(nil, "OVERLAY")
    row.icon:Hide()

    row.iconHit = CreateFrame("Frame", nil, row)
    row.iconHit:Hide()
    row.iconHit:SetScript("OnEnter", function(f)
        local r = f:GetParent()
        if not r then return end
        local name = r.fullName or r.name
        if not name then return end
        GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
        GameTooltip:SetText(name, 1, 1, 1)
        if type(_G.RSTATS_Achiev_AddAchievementInfoToTooltip) == "function" then
            local realm
            if r.fullName then
                local n, rr = r.fullName:match("^([^-]+)%-(.+)$")
                name, realm = n or name, rr
            end
            _G.RSTATS_Achiev_AddAchievementInfoToTooltip(GameTooltip, name, realm)
        elseif r.achievText then
            GameTooltip:AddLine(r.achievText, 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    row.iconHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

    row.nameText = row.hp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)
    if row.nameText.SetMaxLines then row.nameText:SetMaxLines(1) end
    row.nameText:SetTextColor(RS_TEXT_R, RS_TEXT_G, RS_TEXT_B)

    row.hpText = row.hp:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.hpText:SetJustifyH("CENTER")
    row.hpText:SetWordWrap(false)
    if row.hpText.SetMaxLines then row.hpText:SetMaxLines(1) end
    row.hpText:SetTextColor(RS_TEXT_R, RS_TEXT_G, RS_TEXT_B)

    row.specText = row.hp:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.specText:SetJustifyH("RIGHT")
    row.specText:SetWordWrap(false)
    if row.specText.SetMaxLines then row.specText:SetMaxLines(1) end
    row.specText:SetTextColor(RS_TEXT_R, RS_TEXT_G, RS_TEXT_B)
    row.specText:SetText("")

    row.guid = nil
    row.name = nil
    row.fullName = nil
    row.displayName = nil
    row.classFile = nil
    row.role = nil
    row.specID = nil
    row.specName = nil
    row.achievIconTex = nil
    row.achievText = nil
    row.achievTint = nil
    row._seenIdentity = false
    row._preview = false
    row._outOfRange = false
    row._hpSB = nil
    row._pwrSB = nil
    row._barsUnit = nil

    row:HookScript("OnEnter", function()
        local bge = _G.RSTATS_BGE
        if bge then bge:AnchorHoverBegin() end
    end)
    row:HookScript("OnLeave", function()
        local bge = _G.RSTATS_BGE
        if bge then bge:AnchorHoverEnd() end
    end)

    return row
end

function BGE:SetSelectedRow(row)
    if self._selectedRow and self._selectedRow ~= row then
        local r = self._selectedRow
        if r.selectTop then r.selectTop:Hide() end
        if r.selectBottom then r.selectBottom:Hide() end
        if r.selectLeft then r.selectLeft:Hide() end
        if r.selectRight then r.selectRight:Hide() end
    end

    self._selectedRow = row

    if row then
        if row.selectTop then row.selectTop:Show() end
        if row.selectBottom then row.selectBottom:Show() end
        if row.selectLeft then row.selectLeft:Show() end
        if row.selectRight then row.selectRight:Show() end
    end
end

function BGE:SyncSelectedRowToTarget()
    if not SafeUnitExists("target") then
        self:SetSelectedRow(nil)
        return
    end

    for _, row in ipairs(self.rows or {}) do
        if row and row._seenIdentity and row.unit and SafeUnitExists(row.unit) then
            local ok, same = pcall(UnitIsUnit, "target", row.unit)
            if ok and SafeBool(same) then
                self:SetSelectedRow(row)
                return
            end
        end
    end

    local guid = SafeUnitGUID("target")
    if guid and self.rowByGuid[guid] then
        self:SetSelectedRow(self.rowByGuid[guid])
        return
    end

    local full, base = SafeUnitFullName("target")
    local hit = (full and self.rowByDisplayName[full]) or (base and self.rowByBaseName[base])
    self:SetSelectedRow(hit)
end

function BGE:EnsureSecureRows()
    if not self.frame then return end
    if InLockdown() then
        self._rowsDirty = true
        return
    end
    if #self.rows >= self.maxPlates then return end

    for i = #self.rows + 1, self.maxPlates do
        self.rows[i] = MakeRow(self.frame, i)
        self.rows[i]:SetAlpha(0)
    end
end

function BGE:ResolveExpectedRows()
    local prefix, count = ResolveLiveProfilePrefix()
    self._profilePrefix = prefix

    count = tonumber(SafeToString(count)) or 10
    if count < 1 then count = 10 end
    if count > self.maxPlates then count = self.maxPlates end

    self.expectedRows = count
    return count
end

function BGE:GetLayoutRowCount()
    if IsInPVPInstance() then
        return self:ResolveExpectedRows()
    end

    if GetSetting("bgePreview", false) then
        local want = GetSetting("bgePreviewCount", 8)
        want = tonumber(SafeToString(want)) or 8
        if want < 1 then want = 1 end
        if want > self.maxPlates then want = self.maxPlates end
        return want
    end

    return self.expectedRows or 10
end

function BGE:PrimeRosterSlots()
    if not self.frame or not IsInPVPInstance() then return end

    self:EnsureSecureRows()

    local want = self:ResolveExpectedRows()
    for i = 1, self.maxPlates do
        local row = self.rows[i]
        if row then
            if i <= want then
                if not row._seenIdentity then
                    row._placeholder = true
                    row._outOfRange = false
                    row._preview = false
                    row.nameText:SetText("Enemy " .. tostring(i))
                    row.hpText:SetText("")
                    row.specText:SetText("")
                    row.roleIcon:Hide()
                    row.icon:Hide()
                    row.iconHit:Hide()
                    row.hp:SetMinMaxValues(0, 1)
                    row.hp:SetValue(0)
                    row.hp:SetStatusBarColor(0.25, 0.25, 0.25, CLASS_ALPHA_OOR)
                    row.power:SetMinMaxValues(0, 1)
                    row.power:SetValue(0)
                    row.power:Hide()
                    row.bg:SetColorTexture(0, 0, 0, 0.25)
                end
            elseif not row._seenIdentity then
                row._placeholder = false
                row:SetAlpha(0)
            end
        end
    end
end

function BGE:GetRowForPlateUnit(unit)
    if not unit or not SafeUnitExists(unit) or not SafeUnitIsEnemy(unit) then return nil end

    local guid = SafeUnitGUID(unit)
    if guid and self.rowByGuid[guid] then return self.rowByGuid[guid] end

    local display, base = GetNameplateDisplayNames(unit)
    local full, unitBase = SafeUnitFullName(unit)
    base = base or unitBase

    if full and self.rowByDisplayName[full] then return self.rowByDisplayName[full] end
    if display and self.rowByDisplayName[display] then return self.rowByDisplayName[display] end
    if base and self.rowByBaseName[base] then return self.rowByBaseName[base] end

    local want = self:ResolveExpectedRows()
    for i = 1, want do
        local row = self.rows[i]
        if row and not row._seenIdentity then
            return row
        end
    end

    return nil
end

function BGE:ReleaseRow(row, keepSeen)
    if not row then return end

    if row.guid and self.rowByGuid[row.guid] == row then self.rowByGuid[row.guid] = nil end
    if row.displayName and self.rowByDisplayName[row.displayName] == row then self.rowByDisplayName[row.displayName] = nil end
    if row.name and self.rowByBaseName[row.name] == row then self.rowByBaseName[row.name] = nil end

    row.guid = nil
    row.name = nil
    row.fullName = nil
    row.displayName = nil
    row.classFile = nil
    row.role = nil
    row.specID = nil
    row.specName = nil
    row.achievIconTex = nil
    row.achievText = nil
    row.achievTint = nil
    row._seenIdentity = keepSeen and row._seenIdentity or false
    row._placeholder = false
    row._outOfRange = false
    row._preview = false
    row.unit = nil
    row.plateIndex = nil
    if not InLockdown() then
        row:SetAttribute("unit", nil)
        row._secureUnit = nil
    end
    row._hpSB = nil
    row._pwrSB = nil
    row._barsUnit = nil

    row.nameText:SetText("")
    row.hpText:SetText("")
    row.specText:SetText("")
    row.roleIcon:Hide()
    row.icon:Hide()
    row.iconHit:Hide()
    row.hp:SetMinMaxValues(0, 1)
    row.hp:SetValue(0)
    row.power:SetMinMaxValues(0, 1)
    row.power:SetValue(0)
    row.power:Hide()
    row.bg:SetColorTexture(0, 0, 0, 0.35)
    if row.selectTop then row.selectTop:Hide() end
    if row.selectBottom then row.selectBottom:Hide() end
    if row.selectLeft then row.selectLeft:Hide() end
    if row.selectRight then row.selectRight:Hide() end
    row:SetAlpha(0)
end

function BGE:ClearAllRows()
    wipe(self.rowByUnit)
    wipe(self.rowByGuid)
    wipe(self.rowByDisplayName)
    wipe(self.rowByBaseName)
    for _, row in ipairs(self.rows) do
        self:ReleaseRow(row)
    end
end

function BGE:MarkRowMappings(row)
    if not row then return end

    if row.guid then
        local old = self.rowByGuid[row.guid]
        if old and old ~= row then self:ReleaseRow(old) end
        self.rowByGuid[row.guid] = row
    end

    if row.displayName then
        local old = self.rowByDisplayName[row.displayName]
        if old and old ~= row then self:ReleaseRow(old) end
        self.rowByDisplayName[row.displayName] = row
    end

    if row.name then
        local old = self.rowByBaseName[row.name]
        if old and old ~= row then self:ReleaseRow(old) end
        self.rowByBaseName[row.name] = row
    end
end

function BGE:UpdateIdentity(row, unit)
    if not row or not unit or not SafeUnitExists(unit) then return end
    if not SafeUnitIsEnemy(unit) then return end

    local guid = SafeUnitGUID(unit)
    local display, base = GetNameplateDisplayNames(unit)
    local full, unitBase = SafeUnitFullName(unit)
    local _, classFile = SafeUnitClass(unit)

    if not display then display = full end
    if not base then base = unitBase end
    if not full and display and display:find("-", 1, true) then full = display end

    if display then
        local old = self.rowByDisplayName[display]
        if old and old ~= row then
            self:ReleaseRow(old)
        end
    end
    if guid then
        local old = self.rowByGuid[guid]
        if old and old ~= row then
            self:ReleaseRow(old)
        end
    end

    if guid then row.guid = guid end
    if display then row.displayName = display end
    if full then row.fullName = full end
    if base then row.name = base end
    if classFile then row.classFile = classFile end

    if row.name then
        row.nameText:SetText(row.name)
    elseif row.displayName then
        row.nameText:SetText(row.displayName)
    else
        row.nameText:SetText("Enemy")
    end

    row._seenIdentity = true
    row._preview = false
    row.bg:SetColorTexture(0, 0, 0, 0.35)
    ApplyClassAlpha(row, row._outOfRange and CLASS_ALPHA_OOR or CLASS_ALPHA_ACTIVE)

    row.role = nil
    row.specID = nil
    row.specName = nil
    row.roleIcon:Hide()
    row.specText:SetText("")

    local hadIcon = row.achievIconTex
    if row.achievIconTex == nil then
        row.achievIconTex, row.achievText, row.achievTint = GetIconTextureForEnemyName(row.fullName or row.displayName, row.name)
    end
    if row.achievIconTex then
        row.icon:SetTexture(row.achievIconTex)
        if type(row.achievTint) == "table" then
            row.icon:SetVertexColor(tonumber(row.achievTint[1]) or 1, tonumber(row.achievTint[2]) or 1, tonumber(row.achievTint[3]) or 1)
        else
            row.icon:SetVertexColor(1, 1, 1)
        end
        row.icon:Show()
    else
        row.icon:Hide()
    end

    self:MarkRowMappings(row)

    if row.achievIconTex and not hadIcon and not InLockdown() then
        self:ApplyRowLayout(row)
    end

    UpdateNameClipToHPFill(row)
end

function BGE:UpdateHealth(row, unit)
    if not row then return end
    unit = unit or row.unit
    if not unit or not SafeUnitExists(unit) then return end

    if SafeUnitIsDead(unit) then
        row.hp:SetMinMaxValues(0, 1)
        row.hp:SetValue(0)
        row.hpText:SetText("DEAD")
        row._dead = true
        UpdateNameClipToHPFill(row)
        return
    end
    row._dead = false

    local sb = row._hpSB
    if row._barsUnit ~= unit then
        row._barsUnit = unit
        row._hpSB = nil
        row._pwrSB = nil
        sb = nil
    end
    if sb == nil then
        sb = FindPlateHealthStatusBar(unit)
        row._hpSB = sb or false
    elseif sb == false then
        sb = nil
    end

    local cur, maxv = SafeStatusBarValues(sb)
    if cur and maxv then
        pcall(row.hp.SetMinMaxValues, row.hp, 0, maxv)
        pcall(row.hp.SetValue, row.hp, cur)
    end

    local txt = nil
    local mode = GetSetting("bgeHealthTextMode", 2)
    if sb then
        if mode ~= 3 then
            txt = SafePlateHealthNumericText(sb)
        end
        if not txt and cur and maxv then
            txt = FormatHealthText(cur, maxv, mode)
        end
        if not txt then
            local pct = SafePercentFromStatusBarFill(sb)
            if pct then txt = tostring(pct) .. "%" end
        end
    end

    if txt then row.hpText:SetText(txt) end
    UpdateNameClipToHPFill(row)
end

function BGE:UpdatePower(row, unit)
    if not row then return end
    if not GetSetting("bgeShowPower", true) then
        row.power:Hide()
        return
    end

    unit = unit or row.unit
    if not unit or not SafeUnitExists(unit) then
        row.power:Hide()
        return
    end

    local sb = row._pwrSB
    if row._barsUnit ~= unit then
        row._barsUnit = unit
        row._hpSB = nil
        row._pwrSB = nil
        sb = nil
    end
    if sb == nil then
        sb = FindPlatePowerStatusBar(unit)
        row._pwrSB = sb or false
    elseif sb == false then
        sb = nil
    end

    local cur, maxv = SafeStatusBarValues(sb)
    if not cur or not maxv then
        row.power:Hide()
        return
    end

    local r, g, b = ColorFromStatusBar(sb, 0, 0.55, 1)
    row.power:SetMinMaxValues(0, maxv)
    row.power:SetValue(cur)
    row.power:SetStatusBarColor(r, g, b, 0.9)
    row.power:Show()
end

function BGE:GetRowForExternalUnit(unit)
    if not unit or not SafeUnitExists(unit) or not SafeUnitIsEnemy(unit) then return nil end

    for _, row in ipairs(self.rows or {}) do
        if row and row._seenIdentity and row.unit and SafeUnitExists(row.unit) then
            local ok, same = pcall(UnitIsUnit, unit, row.unit)
            if ok and SafeBool(same) then return row end
        end
    end

    local guid = SafeUnitGUID(unit)
    if guid and self.rowByGuid[guid] then return self.rowByGuid[guid] end

    local full, base = SafeUnitFullName(unit)
    if full and self.rowByDisplayName[full] then return self.rowByDisplayName[full] end
    if base and self.rowByBaseName[base] then return self.rowByBaseName[base] end

    return nil
end

function BGE:HandleExternalUnit(unit)
    if not GetSetting("bgeEnabled", true) then return end
    if not IsInPVPInstance() then return end
    if not SafeUnitExists(unit) or not SafeUnitIsEnemy(unit) then return end

    local row = self:GetRowForExternalUnit(unit)
    if not row then return end

    self:UpdateIdentity(row, unit)
    self:UpdateHealth(row, unit)
    self:UpdatePower(row, unit)
    self:UpdateRowVisibilities()
end

function BGE:HandlePlateAdded(unit)
    if not IsNameplateUnit(unit) then return end
    if not GetSetting("bgeEnabled", true) then return end
    if not IsInPVPInstance() then return end
    if not SafeUnitExists(unit) or not SafeUnitIsEnemy(unit) then return end

    self:EnsureSecureRows()

    local idx = NameplateIndex(unit)
    if not idx or idx > self.maxPlates then return end

    local row = self:GetRowForPlateUnit(unit)
    if not row then
        DPrint("PLATE_NO_SLOT:" .. unit, "no roster slot available for " .. unit)
        return
    end

    local old = self.rowByUnit[unit]
    if old and old ~= row then
        old.unit = nil
        old.plateIndex = nil
        old._outOfRange = old._seenIdentity and true or false
        old._hpSB = nil
        old._pwrSB = nil
        old._barsUnit = nil
    end

    self.rowByUnit[unit] = row
    row.unit = unit
    row.plateIndex = idx
    row._placeholder = false
    row._outOfRange = false
    row._preview = false
    row._hpSB = nil
    row._pwrSB = nil
    row._barsUnit = nil

    self:UpdateIdentity(row, unit)
    self:UpdateHealth(row, unit)
    self:UpdatePower(row, unit)
    ApplyClassAlpha(row, CLASS_ALPHA_ACTIVE)

    DPrint("PLATE_ADD:" .. unit, "bound enemy " .. unit .. " name=" .. tostring(row.name or row.displayName or "nil") .. " class=" .. tostring(row.classFile or "nil"))

    self:UpdateRowVisibilities()
    self:SyncSelectedRowToTarget()
end

function BGE:HandlePlateRemoved(unit)
    if not IsNameplateUnit(unit) then return end
    local row = self.rowByUnit[unit]
    if not row then return end

    self.rowByUnit[unit] = nil
    if row.unit == unit then
        row.unit = nil
        row.plateIndex = nil
    end
    row._hpSB = nil
    row._pwrSB = nil
    row._barsUnit = nil
    row._outOfRange = true

    if row._seenIdentity then
        ApplyClassAlpha(row, CLASS_ALPHA_OOR)
        row:SetAlpha(self._oorEnabled and ROW_ALPHA_OOR or ROW_ALPHA_ACTIVE)
    else
        row:SetAlpha(0)
    end

    self:UpdateRowVisibilities()
end

function BGE:HandleUnitUpdate(unit, what, force)
    if not GetSetting("bgeEnabled", true) then return end
    if not IsInPVPInstance() then return end
    if not unit or not SafeUnitExists(unit) then return end

    if IsNameplateUnit(unit) then
        if not SafeUnitIsEnemy(unit) then return end
        local row = self.rowByUnit[unit]
        if not row then
            self:HandlePlateAdded(unit)
            row = self.rowByUnit[unit]
        end
        if not row then return end
        if what == "NAME" then
            self:UpdateIdentity(row, unit)
            self:UpdateRowVisibilities()
        elseif what == "HP" then
            self:UpdateHealth(row, unit)
        elseif what == "PWR" then
            local now = GetTime()
            local last = row._lastPWRAt or 0
            if (not force) and (now - last) < 0.15 then return end
            row._lastPWRAt = now
            self:UpdatePower(row, unit)
        end
        return
    end

    if unit == "target" or unit == "focus" or unit == "mouseover" or unit == "softenemy" then
        self:HandleExternalUnit(unit)
    end
end

function BGE:IsMatchStarted()
    if not (C_PvP and C_PvP.GetActiveMatchState) then return false end
    local ok, state = pcall(C_PvP.GetActiveMatchState)
    if not ok or type(state) ~= "number" then return false end
    if Enum and Enum.PvPMatchState then
        local engaged = Enum.PvPMatchState.Engaged or 3
        return state == engaged
    end
    return state == 3
end

function BGE:UpdateMatchState()
    if not IsInPVPInstance() then
        self._matchStarted = false
        self._oorEnabled = false
        self._enteredBGAt = nil
        return
    end

    self._enteredBGAt = self._enteredBGAt or GetTime()
    self._matchStarted = self:IsMatchStarted()
    if self._matchStarted then
        self._oorEnabled = true
    end
end

function BGE:ScanNameplates()
    if not GetSetting("bgeEnabled", true) then return end
    if not IsInPVPInstance() then return end

    self:EnsureSecureRows()
    self:PrimeRosterSlots()

    for i = 1, self.maxPlates do
        local unit = NameplateUnitFromIndex(i)
        if SafeUnitExists(unit) then
            if SafeUnitIsEnemy(unit) then
                self:HandlePlateAdded(unit)
            else
                self:HandlePlateRemoved(unit)
            end
        end
    end
end

function BGE:StartNameplateScanner()
    if self._nameplateTicker then return end
    self._nameplateTicker = C_Timer.NewTicker(0.50, function()
        local bge = _G.RSTATS_BGE
        if not bge then return end
        if not GetSetting("bgeEnabled", true) or not IsInPVPInstance() then
            bge:StopNameplateScanner()
            return
        end
        bge:ScanNameplates()
    end)
end

function BGE:StopNameplateScanner()
    if self._nameplateTicker then
        self._nameplateTicker:Cancel()
        self._nameplateTicker = nil
    end
end

function BGE:PollLiveBars()
    if not GetSetting("bgeEnabled", true) then return end
    if not IsInPVPInstance() then return end

    for _, row in ipairs(self.rows or {}) do
        if row and row._seenIdentity and not row._preview then
            local unit = row.unit
            if unit and SafeUnitExists(unit) and SafeUnitIsEnemy(unit) then
                self:UpdateHealth(row, unit)
                self:UpdatePower(row, unit)
            end
        end
    end
end

function BGE:StartLiveBarPoller()
    if self._liveBarTicker then return end
    self._liveBarTicker = C_Timer.NewTicker(0.10, function()
        local bge = _G.RSTATS_BGE
        if bge then bge:PollLiveBars() end
    end)
end

function BGE:StopLiveBarPoller()
    if self._liveBarTicker then
        self._liveBarTicker:Cancel()
        self._liveBarTicker = nil
    end
end

function BGE:UpdateRowVisibilities()
    if not self.rows then return end

    if not self._oorEnabled and self:IsMatchStarted() then
        self._oorEnabled = true
    end

    local playerDead = false
    if self._oorEnabled and _G.UnitIsDeadOrGhost then
        local ok, dead = pcall(_G.UnitIsDeadOrGhost, "player")
        playerDead = ok and SafeBool(dead)
    end

    local wantedRows = self:GetLayoutRowCount()

    for i = 1, self.maxPlates do
        local row = self.rows[i]
        if row then
            if i > wantedRows and not row._preview then
                row:SetAlpha(0)
            elseif row._preview then
                row._outOfRange = false
                ApplyClassAlpha(row, CLASS_ALPHA_ACTIVE)
                row:SetAlpha(ROW_ALPHA_ACTIVE)
            elseif row._seenIdentity then
                local unit = row.unit
                local active = unit and SafeUnitExists(unit) and SafeUnitIsEnemy(unit)
                local dead = active and SafeUnitIsDead(unit)

                if dead then
                    row._outOfRange = false
                    ApplyClassAlpha(row, CLASS_ALPHA_DEAD)
                    row:SetAlpha(ROW_ALPHA_DEAD)
                elseif not self._oorEnabled then
                    row._outOfRange = false
                    ApplyClassAlpha(row, CLASS_ALPHA_ACTIVE)
                    row:SetAlpha(ROW_ALPHA_ACTIVE)
                elseif playerDead then
                    row._outOfRange = true
                    ApplyClassAlpha(row, CLASS_ALPHA_OOR)
                    row:SetAlpha(ROW_ALPHA_OOR)
                elseif active then
                    row._outOfRange = false
                    ApplyClassAlpha(row, CLASS_ALPHA_ACTIVE)
                    row:SetAlpha(ROW_ALPHA_ACTIVE)
                else
                    row._outOfRange = true
                    ApplyClassAlpha(row, CLASS_ALPHA_OOR)
                    row:SetAlpha(ROW_ALPHA_OOR)
                end
            else
                if IsInPVPInstance() and i <= wantedRows then
                    row:SetAlpha(ROW_ALPHA_UNKNOWN)
                else
                    row:SetAlpha(0)
                end
            end
        end
    end
end

UpdateNameClipToHPFill = function(row)
    if not row or not row.hp or not row.nameText then return end

    local okW, w = pcall(row.hp.GetWidth, row.hp)
    w = okW and SafeNumber(w) or nil
    if not w or w <= 0 then return end

    local fillW = w
    local tex = row.hp.GetStatusBarTexture and row.hp:GetStatusBarTexture() or nil
    if tex and tex.GetRight and row.hp.GetLeft then
        local okL, left = pcall(row.hp.GetLeft, row.hp)
        local okR, right = pcall(tex.GetRight, tex)
        left = okL and SafeNumber(left) or nil
        right = okR and SafeNumber(right) or nil
        if left and right then
            local okCalc, v = pcall(function() return right - left end)
            if okCalc and type(v) == "number" and (not _G.issecretvalue or not _G.issecretvalue(v)) then
                fillW = v
            end
        end
    end

    if fillW < 0 then fillW = 0 end
    row.nameText:SetWidth(math.max(0, fillW - 6))
end

local PREVIEW_ROSTER = {
    { name = "Druid",        classFile = "DRUID",       role = "HEALER"  },
    { name = "Shaman",       classFile = "SHAMAN",      role = "HEALER"  },
    { name = "Priest",       classFile = "PRIEST",      role = "HEALER"  },
    { name = "Demon Hunter", classFile = "DEMONHUNTER", role = "TANK"    },
    { name = "Warrior",      classFile = "WARRIOR",     role = "DAMAGER" },
    { name = "Paladin",      classFile = "PALADIN",     role = "DAMAGER" },
    { name = "Rogue",        classFile = "ROGUE",       role = "DAMAGER" },
    { name = "Druid",        classFile = "DRUID",       role = "DAMAGER" },
    { name = "Mage",         classFile = "MAGE",        role = "DAMAGER" },
    { name = "Warlock",      classFile = "WARLOCK",     role = "DAMAGER" },
}

function BGE:ClearPreviewRows()
    for _, row in ipairs(self.previewRows) do
        if row then
            row._preview = false
            self:ReleaseRow(row)
        end
    end
    wipe(self.previewRows)
end

function BGE:EnsurePreviewRows()
    if not self.frame then return end
    if IsInPVPInstance() then
        self:ClearPreviewRows()
        return
    end
    if not GetSetting("bgePreview", false) then
        self:ClearPreviewRows()
        return
    end

    self:EnsureSecureRows()

    local want = GetSetting("bgePreviewCount", 8)
    if type(want) ~= "number" or want < 1 then want = 1 end
    if want > #PREVIEW_ROSTER then want = #PREVIEW_ROSTER end

    for i = 1, want do
        local row = self.rows[i]
        local rec = PREVIEW_ROSTER[i]
        if row and rec then
            self.previewRows[i] = row
            row._preview = true
            row._seenIdentity = true
            row.name = rec.name
            row.displayName = rec.name
            row.fullName = nil
            row.classFile = rec.classFile
            row.role = rec.role
            row.specID = nil
            row.specName = nil
            row.nameText:SetText(rec.name)
            row.specText:SetText("")
            row.hp:SetMinMaxValues(0, 100)
            row.hp:SetValue(82 - (i * 3 % 30))
            row.hpText:SetText(FormatHealthText(82 - (i * 3 % 30), 100, GetSetting("bgeHealthTextMode", 2)) or "")
            ApplyClassAlpha(row, CLASS_ALPHA_ACTIVE)
            SetRoleTexture(row.roleIcon, row.role)
            if GetSetting("bgeShowPower", true) then
                row.power:SetMinMaxValues(0, 100)
                row.power:SetValue(65 - (i * 4 % 40))
                row.power:SetStatusBarColor(0, 0.55, 1, 0.9)
                row.power:Show()
            else
                row.power:Hide()
            end
            row:SetAlpha(1)
            UpdateNameClipToHPFill(row)
        end
    end

    for i = want + 1, self.maxPlates do
        local row = self.rows[i]
        if row then self:ReleaseRow(row) end
    end
end

function BGE:ApplyRowLayout(row)
    if not row or InLockdown() then return end

    local w = GetSetting("bgeRowWidth", 240)
    local h = GetSetting("bgeRowHeight", 18)
    if type(w) ~= "number" or w < 50 then w = 240 end
    if type(h) ~= "number" or h < 15 then h = 15 end

    row:SetSize(w, h)

    row.borderTop:ClearAllPoints()
    row.borderTop:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.borderTop:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    row.borderBottom:ClearAllPoints()
    row.borderBottom:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    row.borderBottom:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    row.borderLeft:ClearAllPoints()
    row.borderLeft:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.borderLeft:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    row.borderRight:ClearAllPoints()
    row.borderRight:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    row.borderRight:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)

    row.selectTop:ClearAllPoints()
    row.selectTop:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.selectTop:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    row.selectBottom:ClearAllPoints()
    row.selectBottom:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    row.selectBottom:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    row.selectLeft:ClearAllPoints()
    row.selectLeft:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.selectLeft:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    row.selectRight:ClearAllPoints()
    row.selectRight:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    row.selectRight:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)

    local showPower = GetSetting("bgeShowPower", true)
    local border = 1
    local innerH = h - (border * 2)
    if innerH < 1 then innerH = 1 end
    local powerH = showPower and math.max(2, math.floor(innerH * 0.15)) or 0
    local gap = showPower and 1 or 0
    local hpH = innerH - powerH - gap
    if hpH < 1 then hpH = 1 end

    row.hp:ClearAllPoints()
    row.hp:SetPoint("TOPLEFT", row, "TOPLEFT", border, -border)
    row.hp:SetPoint("TOPRIGHT", row, "TOPRIGHT", -border, -border)
    row.hp:SetHeight(hpH)

    row.power:ClearAllPoints()
    if showPower then
        row.power:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", border, border)
        row.power:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -border, border)
        row.power:SetHeight(powerH)
    else
        row.power:Hide()
    end

    local hasRoleIcon = row.role ~= nil and row._preview == true
    local roleSize = hasRoleIcon and math.floor(math.max(10, math.min(h, 16))) or 0
    if roleSize > 0 then
        roleSize = math.max(10, math.min(roleSize, 96))
        row.roleIcon:ClearAllPoints()
        row.roleIcon:SetSize(roleSize, roleSize)
        row.roleIcon:SetPoint("TOPLEFT", row.hp, "TOPLEFT", 2, 0)
    else
        row.roleIcon:Hide()
    end

    local iconTex = row.achievIconTex
    local iconSize = 8
    local iconPad = 1
    local iconOffset = iconTex and (iconSize + iconPad) or 0
    local nameLeft = 2 + (roleSize > 0 and (roleSize + 2) or 0) + iconOffset

    row.nameText:ClearAllPoints()
    row.nameText:SetPoint("TOPLEFT", row.hp, "TOPLEFT", nameLeft, -1)
    row.nameText:SetJustifyH("LEFT")
    if row.nameText.SetDrawLayer then row.nameText:SetDrawLayer("OVERLAY", 7) end

    if iconTex then
        row.icon:ClearAllPoints()
        row.icon:SetTexture(iconTex)
        row.icon:SetSize(iconSize, iconSize)
        row.icon:SetPoint("LEFT", row.nameText, "LEFT", -(iconSize + iconPad), 1)
        if row.icon.SetDrawLayer then row.icon:SetDrawLayer("OVERLAY", 7) end
        row.icon:Show()
        row.iconHit:ClearAllPoints()
        row.iconHit:SetAllPoints(row.icon)
        row.iconHit:Show()
    else
        row.icon:Hide()
        row.iconHit:Hide()
    end

    row.hpText:ClearAllPoints()
    row.hpText:SetPoint("CENTER", row, "CENTER", 0, -1)
    row.hpText:SetWidth(math.max(0, w - 8))
    if row.hpText.SetDrawLayer then row.hpText:SetDrawLayer("OVERLAY", 7) end

    row.specText:ClearAllPoints()
    row.specText:SetPoint("RIGHT", row.hp, "RIGHT", -4, -1)
    row.specText:SetWidth(math.max(0, math.floor(w * 0.35)))
    if row.specText.SetDrawLayer then row.specText:SetDrawLayer("OVERLAY", 7) end

    local nameMax = w - (roleSize + iconOffset + 12 + math.floor(w * 0.35))
    row.nameText:SetWidth(math.max(20, nameMax))

    if row.hpText.GetFont and row.hpText.SetFont then
        local font, _, flags = row.hpText:GetFont()
        if font then
            local fs = math.floor(math.max(9, math.min(hpH * 0.35, 20)))
            row.hpText:SetFont(font, fs, flags)
        end
    end
end

function BGE:ApplyAnchors()
    if not self.frame then return end
    if InLockdown() then
        self._anchorsDirty = true
        return
    end
    self._anchorsDirty = false

    self:EnsureSecureRows()

    local gap = GetSetting("bgeRowGap", 2)
    local h = GetSetting("bgeRowHeight", 18)
    local cols = GetSetting("bgeColumns", 1)
    local rowsPerCol = GetSetting("bgeRowsPerCol", 20)
    local colGap = GetSetting("bgeColGap", 6)
    local w = GetSetting("bgeRowWidth", 240)

    if type(gap) ~= "number" then gap = 2 end
    if type(h) ~= "number" or h < 15 then h = 15 end
    if type(cols) ~= "number" or cols < 1 then cols = 1 end
    if type(rowsPerCol) ~= "number" or rowsPerCol < 1 then rowsPerCol = 1 end
    if type(colGap) ~= "number" then colGap = 6 end
    if type(w) ~= "number" or w < 50 then w = 240 end

    local layoutRows = self:GetLayoutRowCount()

    for i = 1, self.maxPlates do
        local row = self.rows[i]
        if row then
            row:ClearAllPoints()
            if i <= layoutRows then
                local col = math.floor((i - 1) / rowsPerCol)
                local rix = (i - 1) % rowsPerCol
                row:SetPoint("TOPLEFT", self.frame, "TOPLEFT", col * (w + colGap), -(rix * (h + gap)))
                self:ApplyRowLayout(row)
            end
        end
    end

    local usedCols = math.min(cols, math.max(1, math.ceil(layoutRows / rowsPerCol)))
    local rowsInTallestCol = math.min(rowsPerCol, math.max(1, layoutRows))
    local totalW = (usedCols * w) + ((usedCols - 1) * colGap)
    local totalH = (rowsInTallestCol * (h + gap)) - gap
    if totalH < h then totalH = h end
    self.frame:SetSize(totalW, totalH)
end

function BGE:RefreshVisibility()
    if not self.frame then return end

    if not GetSetting("bgeEnabled", true) then
        self.frame:SetAlpha(0)
        self:StopNameplateScanner()
        self:StopLiveBarPoller()
        return
    end

    local preview = GetSetting("bgePreview", false)
    local inPvp = IsInPVPInstance()

    if inPvp then
        local prefix = ResolveLiveProfilePrefix()
        self._profilePrefix = prefix
    elseif preview then
        local db = GetPlayerDB()
        self._profilePrefix = ResolvePreviewProfilePrefix(db)
    end

    if inPvp or preview then
        if not self.frame:IsShown() then
            if InLockdown() then
                self._showDirty = true
            else
                self.frame:Show()
            end
        end
        self.frame:SetAlpha(1)
        self:EnsureSecureRows()
        if inPvp then
            self:PrimeRosterSlots()
        end
        self:UpdateFrameTeamTint()

        if inPvp then
            self._enteredBGAt = self._enteredBGAt or GetTime()
            self:StartNameplateScanner()
            self:StartLiveBarPoller()
            self:ScanNameplates()
        else
            self:StopNameplateScanner()
            self:StopLiveBarPoller()
            self:EnsurePreviewRows()
        end

        self:UpdateRowVisibilities()
    else
        self:StopNameplateScanner()
        self:StopLiveBarPoller()
        self:ClearPreviewRows()
        self:ClearAllRows()
        self._enteredBGAt = nil
        self._oorEnabled = false
        self._matchStarted = false
        self.frame:SetAlpha(0)
        if not InLockdown() then self.frame:Hide() end
    end
end

function BGE:ApplySettings()
    if not self.frame then
        if (IsInPVPInstance() or GetSetting("bgePreview", false)) and CreateMainFrame then
            CreateMainFrame()
        end
        return
    end

    local showAch = GetSetting("bgeShowAchievIcon", false)
    local apiPresent = (type(_G.RSTATS_Achiev_GetHighestPvpRank) == "function")
    if self._lastShowAchievIcon == nil then self._lastShowAchievIcon = showAch end
    if self._lastAchievAPIPresent == nil then self._lastAchievAPIPresent = apiPresent end
    if showAch ~= self._lastShowAchievIcon or apiPresent ~= self._lastAchievAPIPresent then
        self._lastShowAchievIcon = showAch
        self._lastAchievAPIPresent = apiPresent
        for i = 1, self.maxPlates do
            local row = self.rows[i]
            if row and not row._preview then
                row.achievIconTex = nil
                row.achievText = nil
                row.achievTint = nil
            end
        end
    end

    local locked = GetSetting("bgeLocked", true)
    self.frame:SetMovable(not locked)
    self.frame:EnableMouse(not locked)
    self.frame:SetClampedToScreen(true)

    self.frame:RegisterForDrag("LeftButton")
    self.frame:SetScript("OnDragStart", function(f)
        if GetSetting("bgeLocked", true) then return end
        f:StartMoving()
    end)
    self.frame:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        local p, _, rp, x, y = f:GetPoint(1)
        SetSetting("bgePoint", p)
        SetSetting("bgeRelPoint", rp)
        SetSetting("bgeX", x)
        SetSetting("bgeY", y)
    end)

    if self.frame.anchorTab then
        self.frame.anchorTab:RegisterForDrag("LeftButton")
        self.frame.anchorTab:SetScript("OnDragStart", function()
            if GetSetting("bgeLocked", true) then return end
            self.frame:StartMoving()
        end)
        self.frame.anchorTab:SetScript("OnDragStop", function()
            self.frame:StopMovingOrSizing()
            local p, _, rp, x, y = self.frame:GetPoint(1)
            SetSetting("bgePoint", p)
            SetSetting("bgeRelPoint", rp)
            SetSetting("bgeX", x)
            SetSetting("bgeY", y)
        end)
    end

    self:RefreshVisibility()
    self:ApplyAnchors()
    self:UpdateFrameTeamTint()
    self:UpdateRowVisibilities()
end

CreateMainFrame = function()
    if BGE.frame then return end

    local f = CreateFrame("Frame", "RatedStats_BGE_Frame", UIParent)
    BGE.frame = f

    local p = GetSetting("bgePoint", "LEFT")
    local rp = GetSetting("bgeRelPoint", "LEFT")
    local x = GetSetting("bgeX", 30)
    local y = GetSetting("bgeY", 0)

    f:SetPoint(p, UIParent, rp, x, y)
    f:SetFrameStrata("HIGH")
    f:SetSize(GetSetting("bgeRowWidth", 240), 20)

    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints(true)
    f.bg:SetColorTexture(0, 0, 0, 0)

    f.anchorTab = CreateFrame("Button", nil, f, "ChatTabArtTemplate")
    f.anchorTab:SetPoint("BOTTOMLEFT", f, "TOPLEFT", -2, 2)
    f.anchorTab:SetFrameLevel((f:GetFrameLevel() or 0) + 10)
    f.anchorTab:SetAlpha(0.9)
    f.anchorTab:Hide()
    f.anchorTab:RegisterForClicks("RightButtonUp")

    f.anchorTab.Text = f.anchorTab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.anchorTab.Text:SetPoint("CENTER", f.anchorTab, "CENTER", 0, -5)
    f.anchorTab.Text:SetText("Rated Stats - BGE")

    local w = (f.anchorTab.Text:GetStringWidth() or 60) + 40
    if w < 120 then w = 120 end
    f.anchorTab:SetWidth(w)

    if f.anchorTab.ActiveLeft then f.anchorTab.ActiveLeft:Show() end
    if f.anchorTab.ActiveMiddle then f.anchorTab.ActiveMiddle:Show() end
    if f.anchorTab.ActiveRight then f.anchorTab.ActiveRight:Show() end

    f.anchorTab:HookScript("OnMouseUp", function(tab, button)
        if button ~= "RightButton" then return end
        local bge = _G.RSTATS_BGE
        if bge and bge.ShowAnchorMenu then bge:ShowAnchorMenu(tab) end
    end)
    f.anchorTab:SetScript("OnEnter", function()
        local bge = _G.RSTATS_BGE
        if bge then bge:AnchorHoverBegin() end
    end)
    f.anchorTab:SetScript("OnLeave", function()
        local bge = _G.RSTATS_BGE
        if bge then bge:AnchorHoverEnd() end
    end)

    f:SetScript("OnEnter", function()
        local bge = _G.RSTATS_BGE
        if bge then bge:AnchorHoverBegin() end
    end)
    f:SetScript("OnLeave", function()
        local bge = _G.RSTATS_BGE
        if bge then bge:AnchorHoverEnd() end
    end)

    f:SetAlpha(0)
    f:Hide()

    BGE:ApplySettings()
end

local evt = CreateFrame("Frame")
evt:RegisterEvent("PLAYER_LOGIN")
evt:RegisterEvent("PLAYER_ENTERING_WORLD")
evt:RegisterEvent("ZONE_CHANGED_NEW_AREA")
evt:RegisterEvent("PLAYER_REGEN_ENABLED")
evt:RegisterEvent("PLAYER_DEAD")
evt:RegisterEvent("PLAYER_ALIVE")
evt:RegisterEvent("PLAYER_UNGHOST")
evt:RegisterEvent("PLAYER_TARGET_CHANGED")
evt:RegisterEvent("PLAYER_FOCUS_CHANGED")
evt:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
evt:RegisterEvent("PLAYER_SOFT_ENEMY_CHANGED")
evt:RegisterEvent("NAME_PLATE_UNIT_ADDED")
evt:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
evt:RegisterEvent("UNIT_HEALTH")
evt:RegisterEvent("UNIT_MAXHEALTH")
evt:RegisterEvent("UNIT_NAME_UPDATE")
evt:RegisterEvent("UNIT_POWER_UPDATE")
evt:RegisterEvent("UNIT_MAXPOWER")
evt:RegisterEvent("UNIT_DISPLAYPOWER")
evt:RegisterEvent("PVP_MATCH_ACTIVE")
evt:RegisterEvent("PVP_MATCH_COMPLETE")
pcall(function() evt:RegisterEvent("UNIT_HEALTH_FREQUENT") end)
pcall(function() evt:RegisterEvent("UNIT_POWER_FREQUENT") end)

evt:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" then
        if IsInPVPInstance() or GetSetting("bgePreview", false) then
            CreateMainFrame()
            BGE:ApplySettings()
        end
        return
    end

    if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        BGE:UpdateMatchState()
        if IsInPVPInstance() or GetSetting("bgePreview", false) then
            CreateMainFrame()
        end
        BGE:ApplySettings()
        return
    end

    if event == "PLAYER_REGEN_ENABLED" then
        if BGE._showDirty and BGE.frame then
            BGE._showDirty = false
            BGE.frame:Show()
            BGE:RefreshVisibility()
        end
        if BGE._rowsDirty then
            BGE._rowsDirty = false
            BGE:EnsureSecureRows()
        end
        if BGE._anchorsDirty then
            BGE:ApplyAnchors()
            BGE:UpdateRowVisibilities()
        end
        BGE:PrimeRosterSlots()
        BGE:ScanNameplates()
        return
    end

    if event == "PVP_MATCH_ACTIVE" or event == "PVP_MATCH_COMPLETE" then
        BGE:UpdateMatchState()
        BGE:PrimeRosterSlots()
        BGE:ScanNameplates()
        BGE:UpdateRowVisibilities()
        return
    end

    if event == "PLAYER_DEAD" or event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        BGE:UpdateRowVisibilities()
        return
    end

    if event == "PLAYER_TARGET_CHANGED" then
        BGE:HandleExternalUnit("target")
        BGE:SyncSelectedRowToTarget()
        return
    end

    if event == "PLAYER_FOCUS_CHANGED" then
        BGE:HandleExternalUnit("focus")
        return
    end

    if event == "UPDATE_MOUSEOVER_UNIT" then
        BGE:HandleExternalUnit("mouseover")
        return
    end

    if event == "PLAYER_SOFT_ENEMY_CHANGED" then
        BGE:HandleExternalUnit("softenemy")
        return
    end

    if event == "NAME_PLATE_UNIT_ADDED" then
        local unit = arg1
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                local bge = _G.RSTATS_BGE
                if bge then bge:HandlePlateAdded(unit) end
            end)
        else
            BGE:HandlePlateAdded(unit)
        end
        return
    end

    if event == "NAME_PLATE_UNIT_REMOVED" then
        BGE:HandlePlateRemoved(arg1)
        return
    end

    if event == "UNIT_NAME_UPDATE" then
        BGE:HandleUnitUpdate(arg1, "NAME")
        return
    end

    if event == "UNIT_HEALTH" or event == "UNIT_HEALTH_FREQUENT" or event == "UNIT_MAXHEALTH" then
        BGE:HandleUnitUpdate(arg1, "HP")
        return
    end

    if event == "UNIT_POWER_UPDATE" or event == "UNIT_POWER_FREQUENT" or event == "UNIT_MAXPOWER" or event == "UNIT_DISPLAYPOWER" then
        BGE:HandleUnitUpdate(arg1, "PWR")
        return
    end

end)

SLASH_RSTBGE1 = "/rstbge"
SlashCmdList["RSTBGE"] = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")

    if msg == "preview" or msg == "toggle" or msg == "" then
        local db = GetPlayerDB()
        if not db then
            print("Rated Stats - Battleground Enemies: Rated Stats DB not ready yet.")
            return
        end
        db.settings.bgePreview = not db.settings.bgePreview
        if _G.RSTATS_BGE and _G.RSTATS_BGE.ApplySettings then
            _G.RSTATS_BGE:ApplySettings()
        end
        print("Rated Stats - Battleground Enemies: Preview " .. (db.settings.bgePreview and "ON" or "OFF"))
        return
    end

    if msg == "lock" then
        local db = GetPlayerDB()
        if not db then
            print("Rated Stats - Battleground Enemies: Rated Stats DB not ready yet.")
            return
        end
        db.settings.bgeLocked = not db.settings.bgeLocked
        if _G.RSTATS_BGE and _G.RSTATS_BGE.ApplySettings then
            _G.RSTATS_BGE:ApplySettings()
        end
        print("Rated Stats - Battleground Enemies: " .. (db.settings.bgeLocked and "Locked" or "Unlocked"))
        return
    end

    if msg == "debug" then
        local db = GetPlayerDB()
        if not db then
            print("Rated Stats - Battleground Enemies: Rated Stats DB not ready yet.")
            return
        end
        db.settings.bgeDebug = not db.settings.bgeDebug
        print("Rated Stats - Battleground Enemies: Debug " .. (db.settings.bgeDebug and "ON" or "OFF"))
        return
    end

    if msg == "scan" then
        if _G.RSTATS_BGE and _G.RSTATS_BGE.ScanNameplates then
            _G.RSTATS_BGE:ScanNameplates()
        end
        print("Rated Stats - Battleground Enemies: Nameplates scanned.")
        return
    end

    print("Rated Stats - Battleground Enemies: /rstbge [preview|lock|debug|scan]")
end
