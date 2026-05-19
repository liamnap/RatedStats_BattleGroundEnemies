local addonName, RSTATS = ...
RSTATS = RSTATS or _G.RSTATS

-- Rated Stats - Battleground Enemies
-- 12.0.5 scoreboard-roster + nameplate-live rebuild.
-- Scoreboard seeds enemy roster rows: name, class, faction, race, and best-effort role.
-- Talent spec may be displayed directly from scoreboard values; normal string specs may derive role.
-- Nameplates are used for live binding, health, power, OOR, DEAD state, and class/name fallback.
-- No enemy inspect path. No scoreboard-driven health/power. No role/spec sorting dependency.
-- Secret display values may be passed directly to FontStrings, but are not split, compared, or used as table keys.

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
BGE._scoreboardSeeded = false
BGE._scoreboardEnemyCount = nil
BGE._scoreboardSort = nil
BGE._scoreboardFaction = nil
BGE._scoreboardReasserting = false
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

-- Scoreboard talentSpec can be a secret display value in 12.0.5+.
-- We only pass that value directly to a FontString; do not compare it, key it,
-- or try to convert it into a spec texture.
local SPEC_TEXT_ROTATION_RADIANS = -math.pi / 2
local SPEC_TEXT_SIDE_PADDING = 2

local ROW_ALPHA_ACTIVE   = 1.0
local ROW_ALPHA_OOR      = 0.55
local ROW_ALPHA_DEAD     = 0.50
local ROW_ALPHA_UNKNOWN  = 0.35
local CLASS_ALPHA_ACTIVE = 0.85
local CLASS_ALPHA_OOR    = 0.55
local CLASS_ALPHA_DEAD   = 0.50

local GetSetting
local SetSetting
local CreateMainFrame
local UpdateNameClipToHPFill

local function InLockdown()
    return _G.InCombatLockdown and _G.InCombatLockdown()
end

local function IsSecretValue(v)
    if _G.issecretvalue then
        local ok, secret = pcall(_G.issecretvalue, v)
        return ok and secret == true
    end
    return false
end

local function SafeToString(v)
    local ok, s = pcall(function() return tostring(v) end)
    if not ok or type(s) ~= "string" then return nil end
    if IsSecretValue(s) then return nil end
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

local function DbgValue(v)
    if type(v) == "nil" then return "nil" end
    if IsSecretValue(v) then return "<secret>" end
    local ok, s = pcall(function() return tostring(v) end)
    if not ok or type(s) ~= "string" then return "<" .. type(v) .. ">" end
    if #s > 80 then return s:sub(1, 80) .. "..." end
    return s
end

local function DbgFrameName(frame)
    if not frame then return "nil" end

    if frame.GetName then
        local ok, name = pcall(frame.GetName, frame)
        name = ok and SafeNonEmptyString(name) or nil
        if name then return name end
    end

    if frame.GetObjectType then
        local ok, objectType = pcall(frame.GetObjectType, frame)
        objectType = ok and SafeNonEmptyString(objectType) or nil
        if objectType then return objectType end
    end

    return "<frame>"
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

local function SafeUnitIsPlayer(unit)
    if not SafeUnitExists(unit) then return false end
    if not _G.UnitIsPlayer then return false end
    local ok, isPlayer = pcall(_G.UnitIsPlayer, unit)
    return ok and SafeBool(isPlayer)
end

local function SafeUnitIsEnemyPlayer(unit)
    return SafeUnitIsEnemy(unit) and SafeUnitIsPlayer(unit)
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

local function SafeFrameField(frame, key)
    if not frame or not key then return nil end
    local ok, value = pcall(function() return frame[key] end)
    if not ok then return nil end
    return value
end

local function IsStatusBarFrame(frame)
    if not frame then return false end
    if frame.GetObjectType then
        local ok, objectType = pcall(frame.GetObjectType, frame)
        if ok and objectType == "StatusBar" then return true end
    end
    return frame.GetValue and frame.GetMinMaxValues and frame.SetValue and frame.SetMinMaxValues
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
    if not unit then return nil, nil end

    if _G.GetUnitName then
        local okFull, full = pcall(_G.GetUnitName, unit, true)
        full = okFull and SafeNonEmptyString(full) or nil
        if full then
            local base = full
            local okBase, b = pcall(function() return full:match("^([^-]+)") end)
            if okBase and b and b ~= "" then base = b end
            return full, base
        end

        local okBaseOnly, baseOnly = pcall(_G.GetUnitName, unit, false)
        baseOnly = okBaseOnly and SafeNonEmptyString(baseOnly) or nil
        if baseOnly then
            return baseOnly, baseOnly
        end
    end

    local n, r = SafeUnitName(unit)
    if not n then return nil, nil end
    if r then return n .. "-" .. r, n end
    return n, n
end

local function DisplayNameFromRawName(v)
    if type(v) == "nil" then return nil end

    if _G.Ambiguate then
        local ok, shortName = pcall(_G.Ambiguate, v, "short")
        if ok and type(shortName) ~= "nil" then
            return shortName
        end
    end

    return v
end

local function SafeNameKeysFromRaw(v)
    if type(v) == "nil" or IsSecretValue(v) then return nil, nil end

    local full = SafeNonEmptyString(v)
    if not full then return nil, nil end

    local okBase, base = pcall(function() return full:match("^([^-]+)") end)
    if not okBase or not base or base == "" then base = full end
    return full, base
end

local function RawNameUsableForDisplay(v)
    if type(v) == "nil" then return false end
    if IsSecretValue(v) then return true end
    return SafeNonEmptyString(v) ~= nil
end

local function TryGetUnitDisplayName(unit)
    if not unit then return nil, nil, nil end

    if _G.GetUnitName then
        local okFull, rawFull = pcall(_G.GetUnitName, unit, true)
        if okFull and RawNameUsableForDisplay(rawFull) then
            local display = DisplayNameFromRawName(rawFull)
            local keyFull, keyBase = SafeNameKeysFromRaw(rawFull)
            return display, keyFull, keyBase
        end

        local okBase, rawBase = pcall(_G.GetUnitName, unit, false)
        if okBase and RawNameUsableForDisplay(rawBase) then
            local display = DisplayNameFromRawName(rawBase)
            local keyFull, keyBase = SafeNameKeysFromRaw(rawBase)
            return display, keyFull, keyBase
        end
    end

    if _G.UnitName then
        local ok, rawName, rawRealm = pcall(_G.UnitName, unit)
        if ok and RawNameUsableForDisplay(rawName) then
            local display = DisplayNameFromRawName(rawName)
            if not IsSecretValue(rawName) and not IsSecretValue(rawRealm) then
                local name = SafeNonEmptyString(rawName)
                local realm = SafeNonEmptyString(rawRealm)
                if name and realm then return display, name .. "-" .. realm, name end
                if name then return display, name, name end
            end
            return display, nil, nil
        end
    end

    return nil, nil, nil
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

local function SafeUnitRace(unit)
    if not unit or not _G.UnitRace then return nil, nil end
    local ok, localized, raceFile = pcall(_G.UnitRace, unit)
    if not ok then return nil, nil end
    return SafeNonEmptyString(localized), SafeNonEmptyString(raceFile)
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

local function FindNamePlateUnitFrameChild(plate)
    if not plate or not plate.GetChildren then return nil end

    local okKids, kids = pcall(function() return { plate:GetChildren() } end)
    if not okKids or type(kids) ~= "table" then return nil end

    for i = 1, #kids do
        local child = kids[i]
        if child then
            if SafeFrameField(child, "HealthBarsContainer")
                or SafeFrameField(child, "healthBar")
                or SafeFrameField(child, "name")
            then
                return child
            end
        end
    end

    return nil
end

local function SafePlateFrame(unit)
    local plate = nil

    if _G.NamePlateDriverFrame and _G.NamePlateDriverFrame.GetNamePlateForUnit then
        local okDriver, driverPlate = pcall(_G.NamePlateDriverFrame.GetNamePlateForUnit, _G.NamePlateDriverFrame, unit)
        if okDriver and driverPlate then
            plate = driverPlate
        end
    end

    if not plate and _G.C_NamePlate and _G.C_NamePlate.GetNamePlateForUnit then
        local secure = false
        if _G.issecure then
            local okSecure, isSecure = pcall(_G.issecure)
            secure = okSecure and isSecure or false
        end

        local okC, cPlate = pcall(_G.C_NamePlate.GetNamePlateForUnit, unit, secure)
        if okC and cPlate then
            plate = cPlate
        end
    end

    if not plate then return nil, nil end

    local uf = SafeFrameField(plate, "UnitFrame") or SafeFrameField(plate, "unitFrame")
    if not uf then
        uf = FindNamePlateUnitFrameChild(plate)
    end

    return plate, uf
end

local function GetNameplateDisplayNames(unit)
    local _, uf = SafePlateFrame(unit)
    local rawDisplay = nil

    local function TryFS(fs)
        if type(rawDisplay) ~= "nil" then return end
        if not fs or not fs.GetText then return end
        local okT, t = pcall(fs.GetText, fs)
        if okT and RawNameUsableForDisplay(t) then
            rawDisplay = t
        end
    end

    if uf then
        -- Blizzard's NamePlateUnitFrame owns the name FontString as UnitFrame.name.
        TryFS(uf.name)
        TryFS(uf.Name)
        TryFS(uf.unitName)
        TryFS(uf.UnitName)

        if uf.HealthBarsContainer and uf.HealthBarsContainer.healthBar then
            local hb = uf.HealthBarsContainer.healthBar
            TryFS(hb.UnitName)
            TryFS(hb.unitName)
            TryFS(hb.name)
        end

        if type(rawDisplay) == "nil" and uf.GetRegions then
            local okRegions, regions = pcall(function() return { uf:GetRegions() } end)
            if okRegions and regions then
                for i = 1, #regions do
                    local r = regions[i]
                    if r and r.GetObjectType then
                        local okOT, ot = pcall(r.GetObjectType, r)
                        if okOT and ot == "FontString" then
                            TryFS(r)
                            if type(rawDisplay) ~= "nil" then break end
                        end
                    end
                end
            end
        end
    end

    if type(rawDisplay) ~= "nil" then
        local display = DisplayNameFromRawName(rawDisplay)
        local keyFull, keyBase = SafeNameKeysFromRaw(rawDisplay)
        return display, keyFull, keyBase
    end

    return TryGetUnitDisplayName(unit)
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

    local okKids, kids = pcall(function() return { parent:GetChildren() } end)
    if not okKids or type(kids) ~= "table" then return nil end

    for i = 1, #kids do
        local k = kids[i]
        if k and k ~= skip then
            if IsStatusBarFrame(k) then
                return k
            end

            local nested = FindStatusBar(k, skip)
            if nested then return nested end
        end
    end

    return nil
end

local function FindPlateHealthStatusBar(unit)
    local _, uf = SafePlateFrame(unit)
    if not uf then return nil end

    local healthBarsContainer = SafeFrameField(uf, "HealthBarsContainer")
    local healthBar = SafeFrameField(healthBarsContainer, "healthBar")

    local candidates = {
        healthBar,
        SafeFrameField(uf, "healthBar"),
        SafeFrameField(uf, "HealthBar"),
        SafeFrameField(SafeFrameField(uf, "healthBar"), "bar"),
        SafeFrameField(SafeFrameField(uf, "healthBar"), "healthBar"),
    }

    for i = 1, #candidates do
        local sb = candidates[i]
        if IsStatusBarFrame(sb) then return sb end
    end

    return FindStatusBar(healthBarsContainer) or FindStatusBar(uf)
end

local function FindPlatePowerStatusBar(unit)
    local _, uf = SafePlateFrame(unit)
    if not uf then return nil end

    local powerBarsContainer = SafeFrameField(uf, "PowerBarsContainer")

    local candidates = {
        SafeFrameField(uf, "manabar"),
        SafeFrameField(uf, "manaBar"),
        SafeFrameField(uf, "powerBar"),
        SafeFrameField(uf, "PowerBar"),
        SafeFrameField(powerBarsContainer, "powerBar"),
        SafeFrameField(SafeFrameField(uf, "manabar"), "bar"),
        SafeFrameField(SafeFrameField(uf, "powerBar"), "bar"),
    }

    for i = 1, #candidates do
        local sb = candidates[i]
        if IsStatusBarFrame(sb) then return sb end
    end

    return FindStatusBar(powerBarsContainer)
end

local function SafePercentFromStatusBarFill(sb)
    if not sb or not sb.GetWidth or not sb.GetStatusBarTexture then return nil end

    local okW, w = pcall(sb.GetWidth, sb)
    w = okW and SafeNumber(w) or nil
    if not w or w <= 0 then return nil end

    local okTex, tex = pcall(sb.GetStatusBarTexture, sb)
    if not okTex or not tex then return nil end

    local fillW = nil

    if tex.GetLeft and tex.GetRight then
        local okL, left = pcall(tex.GetLeft, tex)
        local okR, right = pcall(tex.GetRight, tex)
        left = okL and SafeNumber(left) or nil
        right = okR and SafeNumber(right) or nil

        if left and right then
            local okCalc, v = pcall(function() return math.abs(right - left) end)
            if okCalc and type(v) == "number" and (not _G.issecretvalue or not _G.issecretvalue(v)) then
                fillW = v
            end
        end
    end

    if not fillW and tex.GetWidth then
        local okTW, tw = pcall(tex.GetWidth, tex)
        fillW = okTW and SafeNumber(tw) or nil
    end

    if not fillW then return nil end

    local okP, pct = pcall(function() return math.floor((fillW / w) * 100 + 0.5) end)
    if not okP or type(pct) ~= "number" then return nil end

    if pct < 0 then
        pct = 0
    elseif pct > 100 then
        pct = 100
    end

    return pct
end

local function SafePlateHealthNumericText(sb)
    if not sb then return nil end
    local fs = sb.TextString or sb.Text or sb.RightText or sb.LeftText
    if not fs or not fs.GetText then return nil end
    local okT, t = pcall(fs.GetText, fs)
    if not okT then return nil end
    return t
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

local function ClassDisplayName(classFile)
    if not classFile then return nil end
    if LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classFile] then
        return LOCALIZED_CLASS_NAMES_MALE[classFile]
    end
    if LOCALIZED_CLASS_NAMES_FEMALE and LOCALIZED_CLASS_NAMES_FEMALE[classFile] then
        return LOCALIZED_CLASS_NAMES_FEMALE[classFile]
    end
    return SafeNonEmptyString(classFile)
end

local function ApplyClassAlpha(row, a)
    if not row or not row.hp then return end
    local r, g, b = GetClassRGB(row.classFile)
    row.hp:SetStatusBarColor(r, g, b, a or CLASS_ALPHA_ACTIVE)
end

local function FormatHealthText(cur, maxv, mode)
    cur, maxv = SafeNumber(cur), SafeNumber(maxv)
    mode = tonumber(SafeToString(mode)) or 1
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
    if s == "TANK" or s == "HEALER" or s == "DAMAGER" or s == "DAMAGE" then
        return s == "DAMAGE" and "DAMAGER" or s
    end
    return nil
end

local function ScoreboardRoleToRole(roleAssigned)
    if type(roleAssigned) == "nil" then return nil end

    if _G.scrubsecretvalues then
        local ok, clean = pcall(_G.scrubsecretvalues, roleAssigned)
        if ok then
            roleAssigned = clean
        end
    end

    local direct = NormalizeRole(roleAssigned)
    if direct then return direct end

    local s = SafeToString(roleAssigned)
    local n = s and tonumber(s) or nil

    if not n and type(roleAssigned) == "number" and not IsSecretValue(roleAssigned) then
        n = roleAssigned
    end

    if not n then return nil end

    local band = (_G.bit and _G.bit.band) or (_G.bit32 and _G.bit32.band)
    if band then
        if band(n, 4) ~= 0 then return "HEALER" end
        if band(n, 1) ~= 0 then return "TANK" end
        if band(n, 2) ~= 0 then return "DAMAGER" end
    end
    if n == 4 then return "HEALER" end
    if n == 1 then return "TANK" end
    if n == 2 or n == 8 then return "DAMAGER" end
    return nil
end

local function ScoreboardRoleDebug(roleAssigned)
    if type(roleAssigned) == "nil" then return "nil" end

    local s = SafeToString(roleAssigned)
    local n = s and tonumber(s) or nil

    return "s=" .. DbgValue(s)
        .. "/n=" .. DbgValue(n)
        .. "/role=" .. DbgValue(ScoreboardRoleToRole(roleAssigned))
end

local SPEC_ROLE_BY_NAME = {
    BLOOD = "TANK",
    VENGEANCE = "TANK",
    GUARDIAN = "TANK",
    BREWMASTER = "TANK",
    PROTECTION = "TANK",

    RESTORATION = "HEALER",
    PRESERVATION = "HEALER",
    MISTWEAVER = "HEALER",
    HOLY = "HEALER",
    DISCIPLINE = "HEALER",
}

local function RoleFromSpecName(specName, classToken)
    if type(specName) == "nil" or IsSecretValue(specName) then return nil end

    local s = SafeNonEmptyString(specName)
    if not s then return nil end
    local okKey, key = pcall(function()
        return s:gsub("_", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""):upper()
    end)
    if not okKey or type(key) ~= "string" then return nil end

    return SPEC_ROLE_BY_NAME[key]
end

local function SetRoleTexture(tex, role)
    if not tex then return false end
    role = NormalizeRole(role)
    if not role then
        tex:Hide()
        return false
    end

    local atlas
    if _G.GetMicroIconForRole then
        local okAtlas, result = pcall(_G.GetMicroIconForRole, role)
        if okAtlas and type(result) == "string" then
            atlas = result
        end
    end

    atlas = atlas or ({
        TANK = "UI-LFG-RoleIcon-Tank-Micro-GroupFinder",
        HEALER = "UI-LFG-RoleIcon-Healer-Micro-GroupFinder",
        DAMAGER = "UI-LFG-RoleIcon-DPS-Micro-GroupFinder",
    })[role]

    if atlas and tex.SetAtlas then
        local okSet = pcall(tex.SetAtlas, tex, atlas, true)
        if okSet then
            tex:SetTexCoord(0, 1, 0, 1)
            tex:Show()
            return true
        end
    end

    tex:Hide()
    return false
end

local function UpdateSpecTextDisplay(row)
    if not row or not row.specText then return end

    if type(row.specName) ~= "nil" then
        -- Secret spec values are display-only. SetText can receive the value,
        -- but this code must not inspect it or map it into an icon.
        row.specText:SetText(row.specName)
        row.specText:Show()
    else
        row.specText:SetText("")
        row.specText:Hide()
    end
end

local function UpdateRoleDisplay(row)
    if not row then return end

    -- 12.0.5+ does not let us safely turn the scoreboard spec/role value
    -- into a reliable role icon in battlegrounds. Keep the existing texture
    -- object hidden so no empty icon lane is reserved in the row layout.
    if row.roleIcon then
        row.roleIcon:Hide()
    end

    UpdateSpecTextDisplay(row)
end

local function ScoreboardRoleForUnit(unit)
    if not unit or not _G.C_PvP or not _G.C_PvP.GetScoreInfoByPlayerGuid then return nil, nil end

    local guid = SafeUnitGUID(unit)
    if not guid then return nil, nil end

    local okInfo, info = pcall(_G.C_PvP.GetScoreInfoByPlayerGuid, guid)

    local classToken = SafeNonEmptyString(info.classToken)
    local specName = SafeNonEmptyString(info.talentSpec)
    local assignedRole = ScoreboardRoleToRole(info.roleAssigned)
    local specRole = RoleFromSpecName(specName, classToken)
    local role = assignedRole or specRole

    return role, specName
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
    row.index = index
    row._seenPlate = false
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
    row.bg:SetTexture("Interface\\RaidFrame\\Raid-Bar-Hp-Bg")
    row.bg:SetVertexColor(0.10, 0.10, 0.10, 0.95)

    row.borderTop = row:CreateTexture(nil, "BORDER")
    row.borderTop:SetColorTexture(0, 0, 0, 0.95)
    row.borderBottom = row:CreateTexture(nil, "BORDER")
    row.borderBottom:SetColorTexture(0, 0, 0, 0.95)
    row.borderLeft = row:CreateTexture(nil, "BORDER")
    row.borderLeft:SetColorTexture(0, 0, 0, 0.95)
    row.borderRight = row:CreateTexture(nil, "BORDER")
    row.borderRight:SetColorTexture(0, 0, 0, 0.95)

    row.selectTop = row:CreateTexture(nil, "OVERLAY")
    row.selectTop:SetColorTexture(1.00, 0.82, 0.00, 1.00)
    row.selectTop:SetHeight(1)
    row.selectTop:Hide()
    row.selectBottom = row:CreateTexture(nil, "OVERLAY")
    row.selectBottom:SetColorTexture(1.00, 0.82, 0.00, 1.00)
    row.selectBottom:SetHeight(1)
    row.selectBottom:Hide()
    row.selectLeft = row:CreateTexture(nil, "OVERLAY")
    row.selectLeft:SetColorTexture(1.00, 0.82, 0.00, 1.00)
    row.selectLeft:SetWidth(1)
    row.selectLeft:Hide()
    row.selectRight = row:CreateTexture(nil, "OVERLAY")
    row.selectRight:SetColorTexture(1.00, 0.82, 0.00, 1.00)
    row.selectRight:SetWidth(1)
    row.selectRight:Hide()

    row.hp = CreateFrame("StatusBar", nil, row)
    row.hp:SetMinMaxValues(0, 1)
    row.hp:SetValue(0)
    row.hp:SetStatusBarTexture("Interface\\RaidFrame\\Raid-Bar-Hp-Fill")
    row.hp:SetStatusBarColor(0.10, 0.90, 0.10, CLASS_ALPHA_ACTIVE)

    row.power = CreateFrame("StatusBar", nil, row)
    row.power:SetMinMaxValues(0, 1)
    row.power:SetValue(0)
    row.power:SetStatusBarTexture("Interface\\RaidFrame\\Raid-Bar-Resource-Fill")
    row.power:SetStatusBarColor(0.0, 0.55, 1.0, 0.90)
    row.power:Hide()

    row.roleIcon = row.hp:CreateTexture(nil, "OVERLAY")
    row.roleIcon:SetTexCoord(0, 1, 0, 1)
    row.roleIcon:Hide()

    row.icon = row.hp:CreateTexture(nil, "OVERLAY")
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
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
    row.specText:SetJustifyH("CENTER")
    if row.specText.SetJustifyV then row.specText:SetJustifyV("MIDDLE") end
    row.specText:SetWordWrap(false)
    if row.specText.SetMaxLines then row.specText:SetMaxLines(1) end
    if row.specText.SetRotation then row.specText:SetRotation(SPEC_TEXT_ROTATION_RADIANS) end
    row.specText:SetTextColor(RS_TEXT_R, RS_TEXT_G, RS_TEXT_B)
    row.specText:SetText("")
    row.specText:Hide()

    row.guid = nil
    row.name = nil
    row.fullName = nil
    row.displayName = nil
    row.displayText = nil
    row.raceName = nil
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
    row._hasLiveHP = false

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
        local want = self:ResolveExpectedRows()
        local scoreCount = tonumber(self._scoreboardEnemyCount) or 0
        if scoreCount > want then want = scoreCount end
        if want < 1 then want = 1 end
        if want > self.maxPlates then want = self.maxPlates end
        self.expectedRows = want
        return want
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

    local want = self:GetLayoutRowCount()
    for i = 1, self.maxPlates do
        local row = self.rows[i]
        if row then
            if i <= want then
                if not row._seenIdentity and not row._seenPlate and not row.unit then
                    row._placeholder = true
                    row._outOfRange = false
                    row._preview = false
                    row._hasLiveHP = false
                    row._lastHPText = nil
                    row.nameText:SetText("Enemy " .. tostring(i))
                    row.hpText:SetText("")
                    row.specText:SetText("")
                    row.specText:Hide()
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
            elseif not row._seenIdentity and not row._seenPlate and not row.unit then
                row._placeholder = false
                row:SetAlpha(0)
            end
        end
    end
end

function BGE:RequestScoreboardData()
    if _G.RequestBattlefieldScoreData then
        pcall(_G.RequestBattlefieldScoreData)
    end
end

function BGE:EnsureScoreboardFeed()
    if self._scoreboardReasserting then return false end

    local scoreboardShown = false
    if _G.PVPMatchScoreboard and _G.PVPMatchScoreboard.IsShown then
        local ok, shown = pcall(_G.PVPMatchScoreboard.IsShown, _G.PVPMatchScoreboard)
        scoreboardShown = ok and SafeBool(shown) or false
    end
    if (not scoreboardShown) and _G.PVPMatchResults and _G.PVPMatchResults.IsShown then
        local ok, shown = pcall(_G.PVPMatchResults.IsShown, _G.PVPMatchResults)
        scoreboardShown = ok and SafeBool(shown) or false
    end

    if scoreboardShown then return false end

    if _G.SortBattlefieldScoreData and self._scoreboardSort ~= "class" then
        self._scoreboardReasserting = true
        local ok = pcall(_G.SortBattlefieldScoreData, "class")
        self._scoreboardReasserting = false
        if ok then
            self._scoreboardSort = "class"
            return true
        end
    end

    if _G.SetBattlefieldScoreFaction and self._scoreboardFaction ~= -1 then
        self._scoreboardReasserting = true
        local ok = pcall(_G.SetBattlefieldScoreFaction, -1)
        self._scoreboardReasserting = false
        if ok then
            self._scoreboardFaction = -1
            return true
        end
    end

    return false
end

function BGE:ApplyScoreboardRosterRow(row, info, rowIndex, scoreIndex)
    if not row or type(info) ~= "table" then return end

    local rawName = info.name
    local displayText = DisplayNameFromRawName(rawName)
    local keyFull, keyBase = SafeNameKeysFromRaw(rawName)
    local guid = SafeNonEmptyString(info.guid)
    local classToken = SafeNonEmptyString(info.classToken)
    local raceName = SafeNonEmptyString(info.raceName)

    local specDisplay = nil
    local specName = nil

    if type(info.talentSpec) ~= "nil" then
        if IsSecretValue(info.talentSpec) then
            -- Secret display values can be printed/passed to FontStrings, but cannot be safely compared.
            specDisplay = info.talentSpec

            if _G.scrubsecretvalues then
                local ok, clean = pcall(_G.scrubsecretvalues, info.talentSpec)
                if ok then
                    specName = SafeNonEmptyString(clean)
                    if specName and type(specDisplay) == "nil" then
                        specDisplay = specName
                    end
                end
            end
        else
            specName = SafeNonEmptyString(info.talentSpec)
            specDisplay = specName
        end
    end

	if not specName and _G.GetBattlefieldScore then
		scoreIndex = tonumber(SafeToString(scoreIndex))
		if scoreIndex then
			local okLegacy, legacySpec16, legacySpec17 = pcall(function()
				local _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, talentSpec, maybeTalentSpec = _G.GetBattlefieldScore(scoreIndex)
				return talentSpec, maybeTalentSpec
			end)
			if okLegacy then
				local legacySpec = SafeNonEmptyString(legacySpec16) or SafeNonEmptyString(legacySpec17)
                if legacySpec then
                    specName = legacySpec
                    if type(specDisplay) == "nil" then
                        specDisplay = legacySpec
                    end
                end
			end
		end
	end

    local specRole = RoleFromSpecName(specName, classToken)
	local assignedRole = ScoreboardRoleToRole(info.roleAssigned)
	local role = specRole or assignedRole
    local sameIdentity =
        (guid and row.guid == guid)
        or (keyFull and (row.displayName == keyFull or row.fullName == keyFull))
        or (keyBase and row.name == keyBase)

    if row.unit then
        local activeClass = select(2, SafeUnitClass(row.unit))
        if activeClass and classToken and activeClass ~= classToken then
            if self.rowByUnit[row.unit] == row then self.rowByUnit[row.unit] = nil end
            if not InLockdown() then
                row:SetAttribute("unit", nil)
                row._secureUnit = nil
            end
            row.unit = nil
            row.plateIndex = nil
            row._hpSB = nil
            row._pwrSB = nil
            row._barsUnit = nil
            row._hasLiveHP = false
        end
    end

    if guid then row.guid = guid end
    if keyFull then row.displayName = keyFull end
    if keyFull then row.fullName = keyFull end
    if keyBase then row.name = keyBase end
    if type(displayText) ~= "nil" then row.displayText = displayText end
    if classToken then row.classFile = classToken end
    if raceName then row.raceName = raceName end
    if role or not sameIdentity then
        row.role = role
    end
    if type(specDisplay) ~= "nil" or not sameIdentity then
        row.specName = specDisplay
    end

    if GetSetting("bgeDebug", false) then
        DPrint(
            "HP_SCOREBOARD_ROW:" .. tostring(rowIndex or row.index or "?"),
            "hp scoreboard row="
            .. DbgValue(rowIndex or row.index)
            .. " name=" .. DbgValue(keyFull or keyBase or rawName)
            .. " spec=" .. DbgValue(specDisplay)
            .. " class=" .. DbgValue(classToken)
            .. " liveHP=" .. Bool01(row._hasLiveHP)
            .. " unit=" .. DbgValue(row.unit)
        )
    end

    row._scoreboardSeen = true
    row._seenIdentity = true
    row._placeholder = false
    row._preview = false
    row._outOfRange = false

    if type(row.displayText) ~= "nil" then
        row.nameText:SetText(row.displayText)
    elseif row.name then
        row.nameText:SetText(row.name)
    elseif row.displayName then
        row.nameText:SetText(row.displayName)
    else
        row.nameText:SetText("Enemy " .. tostring(rowIndex or row.index or ""))
    end

    UpdateRoleDisplay(row)

    row.bg:SetColorTexture(0, 0, 0, 0.35)
	if row.classFile then
		if not row._hasLiveHP then
			row.hp:SetMinMaxValues(0, 1)
			row.hp:SetValue(1)
		end
		ApplyClassAlpha(row, CLASS_ALPHA_ACTIVE)
	end
    if not row._hasLiveHP and not row._dead then
        row.hpText:SetText("")
    end

    local hadIcon = row.achievIconTex
    if (keyFull or keyBase) and row.achievIconTex == nil then
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
        row.iconHit:Show()
    else
        row.icon:Hide()
        row.iconHit:Hide()
    end
    if row.achievIconTex ~= hadIcon then UpdateNameClipToHPFill(row) end

    self:MarkRowMappings(row)
    row:SetAlpha(ROW_ALPHA_ACTIVE)
    self:ApplyRowLayout(row)
end

function BGE:SeedRosterFromScoreboard()
    if not GetSetting("bgeEnabled", true) then return end
    if not IsInPVPInstance() then return end
    if self:IsMatchStarted() then return end
    if not (_G.C_PvP and _G.C_PvP.GetScoreInfo and _G.GetNumBattlefieldScores) then return end
    if self._scoreboardReasserting then return end

    self:EnsureSecureRows()
    self:RequestScoreboardData()
    self:EnsureScoreboardFeed()

    local enemyFaction = GetEnemyFactionIndex()
    if enemyFaction == nil then return end

    local okCount, count = pcall(_G.GetNumBattlefieldScores)
    count = okCount and tonumber(SafeToString(count)) or 0
    if count <= 0 then return end

    local enemies = {}
    for i = 1, count do
        local okInfo, info = pcall(_G.C_PvP.GetScoreInfo, i)
        if okInfo and type(info) == "table" then
            local faction = NormalizeFactionIndex(info.faction)

			if faction == enemyFaction and type(info.name) ~= "nil" then
				enemies[#enemies + 1] = {
					info = info,
					scoreIndex = i,
				}
			end
        end
    end

    local enemyCount = #enemies
    if enemyCount <= 0 then return end
    if enemyCount > self.maxPlates then enemyCount = self.maxPlates end
    self._scoreboardEnemyCount = enemyCount
    self.expectedRows = math.max(self.expectedRows or 0, enemyCount)

    self:PrimeRosterSlots()

    local roleCount = 0
    local specCount = 0
	for i = 1, enemyCount do
		local row = self.rows[i]
		local enemy = enemies[i]
		if row and enemy then
			self:ApplyScoreboardRosterRow(row, enemy.info, i, enemy.scoreIndex)
            if row.role then roleCount = roleCount + 1 end
            if row.specName then specCount = specCount + 1 end
		end
	end

    self._scoreboardRoleCount = roleCount
    self._scoreboardSpecCount = specCount

    self._scoreboardSeeded = true
    local liveHP = 0
    for i = 1, enemyCount do
        local row = self.rows and self.rows[i]
        if row and row._hasLiveHP then
            liveHP = liveHP + 1
        end
    end

    DPrint(
        "HP_SCOREBOARD_SEED",
        "hp scoreboard seeded="
        .. tostring(enemyCount)
        .. " specs=" .. tostring(specCount)
        .. " liveHP=" .. tostring(liveHP)
        .. "/" .. tostring(enemyCount)
    )
    self:UpdateRowVisibilities()
end

function BGE:GetRowForPlateUnit(unit)
    if not unit or not SafeUnitExists(unit) or not SafeUnitIsEnemyPlayer(unit) then return nil end

    local existing = self.rowByUnit and self.rowByUnit[unit]
    if existing then return existing end

    local guid = SafeUnitGUID(unit)
    if guid and self.rowByGuid[guid] then return self.rowByGuid[guid] end

    local _, keyFull, keyBase = GetNameplateDisplayNames(unit)
    local full, unitBase = SafeUnitFullName(unit)
    keyFull = keyFull or full
    keyBase = keyBase or unitBase

    if keyFull and self.rowByDisplayName[keyFull] then return self.rowByDisplayName[keyFull] end
    if keyBase and self.rowByBaseName[keyBase] then return self.rowByBaseName[keyBase] end

    local _, classFile = SafeUnitClass(unit)
    local raceName = SafeUnitRace(unit)
    local want = self:GetLayoutRowCount()

    -- Scoreboard rows already know the roster. Attach live nameplates to those rows first.
    -- Race is used when available; otherwise take the first unbound same-class row
    if classFile then
        for i = 1, want do
            local row = self.rows[i]
            if row and row._scoreboardSeen and not row.unit and row.classFile == classFile then
                if not row.raceName or not raceName or row.raceName == raceName then
                    return row
                end
            end
        end
    end

    for i = 1, want do
        local row = self.rows[i]
        if row and not row.unit and not row._seenIdentity and not row._seenPlate then
            return row
        end
    end

    for i = 1, want do
        local row = self.rows[i]
        if row and not row.unit and not row._seenIdentity then
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
    row.displayText = nil
    row.raceName = nil
    row.classFile = nil
    row.role = nil
    row.specID = nil
    row.specName = nil
    row.achievIconTex = nil
    row.achievText = nil
    row.achievTint = nil
    row._scoreboardSeen = keepSeen and row._scoreboardSeen or false
    row._seenIdentity = keepSeen and row._seenIdentity or false
    row._seenPlate = keepSeen and row._seenPlate or false
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
    row._lastHPText = nil

    row.nameText:SetText("")
    row.hpText:SetText("")
    row.specText:SetText("")
    row.specText:Hide()
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
    self._scoreboardSeeded = false
    self._scoreboardEnemyCount = nil
    self._debugPrintedSpecs = nil
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
    if not SafeUnitIsEnemyPlayer(unit) then return end

    local guid = SafeUnitGUID(unit)
    local displayText, keyFull, keyBase = GetNameplateDisplayNames(unit)
    local full, unitBase = SafeUnitFullName(unit)
    local _, classFile = SafeUnitClass(unit)

    keyFull = keyFull or full
    keyBase = keyBase or unitBase

    if keyFull then
        local old = self.rowByDisplayName[keyFull]
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
    if keyFull then row.displayName = keyFull end
    if keyFull then row.fullName = keyFull end
    if keyBase then row.name = keyBase end
    if type(displayText) ~= "nil" then row.displayText = displayText end
    if classFile then row.classFile = classFile end

    local role, specName = ScoreboardRoleForUnit(unit)
    if role then row.role = role end
    if specName then row.specName = specName end

    local hasKeyIdentity = guid or keyFull or keyBase

    if type(row.displayText) ~= "nil" then
        -- Secret names can be displayed, but not safely split, compared, or used as table keys.
        row.nameText:SetText(row.displayText)
    elseif row.name then
        row.nameText:SetText(row.name)
    elseif row.displayName then
        row.nameText:SetText(row.displayName)
    else
        local cls = ClassDisplayName(row.classFile)
        if cls then
            row.nameText:SetText("Enemy " .. cls)
        else
            row.nameText:SetText("Enemy")
        end
    end

    row._seenPlate = true
    if hasKeyIdentity or row._scoreboardSeen then
        row._seenIdentity = true
    end
    row._preview = false
    row.bg:SetColorTexture(0, 0, 0, 0.35)
    ApplyClassAlpha(row, row._outOfRange and CLASS_ALPHA_OOR or CLASS_ALPHA_ACTIVE)

    UpdateRoleDisplay(row)

    local hadIcon = row.achievIconTex
    if hasKeyIdentity and row.achievIconTex == nil then
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
        row.iconHit:Show()
    else
        row.icon:Hide()
        row.iconHit:Hide()
    end
    if row.achievIconTex ~= hadIcon then UpdateNameClipToHPFill(row) end

    self:MarkRowMappings(row)
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
        row._hasLiveHP = true
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
    if sb == nil or sb == false then
        sb = FindPlateHealthStatusBar(unit)
        row._hpSB = sb
    end

    local cur, maxv = SafeStatusBarValues(sb)
    local pct = nil
    if cur and maxv then
        pcall(row.hp.SetMinMaxValues, row.hp, 0, maxv)
        pcall(row.hp.SetValue, row.hp, cur)
        row._hasLiveHP = true
    else
        pct = SafePercentFromStatusBarFill(sb)
        if pct then
            row.hp:SetMinMaxValues(0, 100)
            row.hp:SetValue(pct)
            row._hasLiveHP = true
        end
    end

    local mode = GetSetting("bgeHealthTextMode", 2)
    local txt = nil
    if cur and maxv then
        txt = FormatHealthText(cur, maxv, mode)
    end

    if not txt and sb then
        mode = tonumber(SafeToString(mode)) or 1
        if mode == 3 then
            pct = pct or SafePercentFromStatusBarFill(sb)
            if pct then txt = tostring(pct) .. "%" end
        else
            txt = SafePlateHealthNumericText(sb)
        end
    end

    if not txt then
        pct = pct or SafePercentFromStatusBarFill(sb)
        if pct then txt = tostring(pct) .. "%" end
    end

    if txt then
        row.hpText:SetText(txt)
        row._hasLiveHP = true
        row._lastHPText = txt
    elseif row._lastHPText then
        row.hpText:SetText(row._lastHPText)
    else
        row.hpText:SetText("")
    end

    local dbgPlate, dbgUF = SafePlateFrame(unit)
    local dbgHBC = SafeFrameField(dbgUF, "HealthBarsContainer")
    local dbgHB = SafeFrameField(dbgHBC, "healthBar")

    DPrint(
        "HP_UPDATE:" .. tostring(row.index or "?"),
        "hp update row=" .. DbgValue(row.index)
        .. " unit=" .. DbgValue(unit)
        .. " name=" .. DbgValue(row.displayName or row.name)
        .. " liveHP=" .. Bool01(row._hasLiveHP)
        .. " txt=" .. DbgValue(txt)
        .. " cur=" .. DbgValue(cur)
        .. " max=" .. DbgValue(maxv)
        .. " pct=" .. DbgValue(pct)
        .. " sb=" .. DbgFrameName(sb)
        .. " plate=" .. DbgFrameName(dbgPlate)
        .. " uf=" .. DbgFrameName(dbgUF)
        .. " hbc=" .. DbgFrameName(dbgHBC)
        .. " hb=" .. DbgFrameName(dbgHB)
    )

    if GetSetting("bgeDebug", false) and type(txt) ~= "nil" then
        local key = "HP_RAW_TEXT:" .. tostring(row.index or "?")
        local now = GetTime()
        local last = BGE._dbgLast[key] or 0
        if (now - last) >= 1.0 then
            BGE._dbgLast[key] = now
            pcall(print, "|cffb69e86[RSTATS-BGE]|r hp raw text row=", row.index, "unit=", unit, "name=", row.displayName or row.name, "txt=", txt)
        end
    end

    UpdateNameClipToHPFill(row)
end

local function SafeUnitPowerPercent(unit)
    if not unit or not _G.UnitPowerPercent then return nil, 0, 0.55, 1, nil, nil end

    local powerType, powerToken = nil, nil
    if _G.UnitPowerType then
        local okType, pType, pToken = pcall(_G.UnitPowerType, unit)
        powerType = okType and SafeNumber(pType) or nil
        powerToken = okType and SafeNonEmptyString(pToken) or nil
    end

    local r, g, b = 0, 0.55, 1
    if _G.PowerBarColor then
        local info = (powerToken and _G.PowerBarColor[powerToken]) or (powerType and _G.PowerBarColor[powerType])
        if info then
            r = SafeNumber(info.r) or r
            g = SafeNumber(info.g) or g
            b = SafeNumber(info.b) or b
        end
    end

    local okPct, pct
    if powerType ~= nil then
        okPct, pct = pcall(_G.UnitPowerPercent, unit, powerType, false)
    else
        okPct, pct = pcall(_G.UnitPowerPercent, unit)
    end

    pct = okPct and SafeNumber(pct) or nil
    if not pct then return nil, r, g, b, powerType, powerToken end

    -- Guard both possible styles: 0..1 fraction or 0..100 percentage.
    if pct <= 1 then
        pct = pct * 100
    end

    if pct < 0 then
        pct = 0
    elseif pct > 100 then
        pct = 100
    end

    return pct, r, g, b, powerType, powerToken
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
    if sb == nil or sb == false then
        sb = FindPlatePowerStatusBar(unit)
        row._pwrSB = sb
    end

    local cur, maxv = SafeStatusBarValues(sb)
    local r, g, b = ColorFromStatusBar(sb, 0, 0.55, 1)
    local pctFromAPI, powerType, powerToken = nil, nil, nil

    if not cur or not maxv then
        pctFromAPI, r, g, b, powerType, powerToken = SafeUnitPowerPercent(unit)
        if pctFromAPI then
            cur = pctFromAPI
            maxv = 100
        end
    end

    if not cur or not maxv or maxv <= 0 then
        local pct = SafePercentFromStatusBarFill(sb)
        if pct then
            row.power:SetMinMaxValues(0, 100)
            row.power:SetValue(pct)
            row.power:SetStatusBarColor(r, g, b, 0.9)
            row.power:Show()
            return
        end

        row.power:Hide()

        return
    end

    row.power:SetMinMaxValues(0, maxv)
    row.power:SetValue(cur)
    row.power:SetStatusBarColor(r, g, b, 0.9)
    row.power:Show()
end

function BGE:GetRowForExternalUnit(unit)
    if not unit or not SafeUnitExists(unit) or not SafeUnitIsEnemyPlayer(unit) then return nil end

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

function BGE:WarmupTargetOneMissingHealthRow()
    if not GetSetting("bgeEnabled", true) then return end
    if not IsInPVPInstance() then return end
    if self:IsMatchStarted() then return end
    if not _G.TargetUnit then return end

    local expected = tonumber(self:ResolveExpectedRows()) or 10

    for i = 1, expected do
        local row = self.rows and self.rows[i]
        if row and row._seenIdentity and not row._hasLiveHP then
            local targetAttempts = {
                { label = "base", name = SafeNonEmptyString(row.name), exact = false },
                { label = "baseExact", name = SafeNonEmptyString(row.name), exact = true },
                { label = "display", name = SafeNonEmptyString(row.displayName), exact = false },
                { label = "displayExact", name = SafeNonEmptyString(row.displayName), exact = true },
                { label = "full", name = SafeNonEmptyString(row.fullName), exact = false },
                { label = "fullExact", name = SafeNonEmptyString(row.fullName), exact = true },
            }

            for n = 1, #targetAttempts do
                local attempt = targetAttempts[n]
                local targetName = attempt and attempt.name
                if targetName then
                    local beforeFull, beforeBase = SafeUnitFullName("target")
                    local ok, err = pcall(_G.TargetUnit, targetName, attempt.exact)

                    self:HandleExternalUnit("target")
                    self:ScanNameplates()
                    self:UpdateRowVisibilities()

                    local afterFull, afterBase = SafeUnitFullName("target")
                    local matched = false

                    local targetRow = self:GetRowForExternalUnit("target")
                    if targetRow and targetRow == row then
                        matched = true
                    end

                    DPrint(
                        "HP_TARGET_PROBE:" .. tostring(i) .. ":" .. tostring(n),
                        "target probe row=" .. tostring(i)
                        .. " mode=" .. DbgValue(attempt.label)
                        .. " try=" .. DbgValue(targetName)
                        .. " exact=" .. Bool01(attempt.exact)
                        .. " ok=" .. Bool01(ok)
                        .. " err=" .. DbgValue(err)
                        .. " before=" .. DbgValue(beforeFull or beforeBase)
                        .. " after=" .. DbgValue(afterFull or afterBase)
                        .. " matched=" .. Bool01(matched)
                        .. " liveHP=" .. Bool01(row._hasLiveHP)
                    )

                    if matched or row._hasLiveHP then
                        return
                    end
                end
            end

            return
        end
    end
end

function BGE:HandleExternalUnit(unit)
    if not GetSetting("bgeEnabled", true) then return end
    if not IsInPVPInstance() then return end
    if not SafeUnitExists(unit) or not SafeUnitIsEnemyPlayer(unit) then return end

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
    if not SafeUnitExists(unit) or not SafeUnitIsEnemyPlayer(unit) then return end

    self:EnsureSecureRows()

    local idx = NameplateIndex(unit)
    if not idx or idx > self.maxPlates then return end

    local row = self:GetRowForPlateUnit(unit)
    if not row then
        local displayText, keyFull, keyBase = GetNameplateDisplayNames(unit)
        local _, classFile = SafeUnitClass(unit)
        DPrint(
            "HP_MAP_FAIL:" .. tostring(unit),
            "hp map failed unit=" .. DbgValue(unit)
            .. " display=" .. DbgValue(displayText)
            .. " full=" .. DbgValue(keyFull)
            .. " base=" .. DbgValue(keyBase)
            .. " class=" .. DbgValue(classFile)
        )
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

    DPrint(
        "HP_MAP_OK:" .. tostring(row.index or "?"),
        "hp map ok row=" .. DbgValue(row.index)
        .. " unit=" .. DbgValue(unit)
        .. " name=" .. DbgValue(row.displayName or row.name)
        .. " class=" .. DbgValue(row.classFile)
        .. " liveHP=" .. Bool01(row._hasLiveHP)
        .. " hpText=" .. DbgValue(row.hpText and row.hpText:GetText())
        .. " hpSB=" .. DbgFrameName(row._hpSB)
    )
    
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

    if row._seenIdentity then
        row._outOfRange = true
        ApplyClassAlpha(row, CLASS_ALPHA_OOR)
        row:SetAlpha(self._oorEnabled and ROW_ALPHA_OOR or ROW_ALPHA_ACTIVE)
    else
        row._seenPlate = false
        row._outOfRange = false
        if row._scoreboardSeen then
            row._seenIdentity = true
            row._placeholder = false
            row.hpText:SetText("")
            row.hp:SetMinMaxValues(0, 1)
            row.hp:SetValue(1)
            ApplyClassAlpha(row, self._oorEnabled and CLASS_ALPHA_OOR or CLASS_ALPHA_ACTIVE)
            row.power:SetMinMaxValues(0, 1)
            row.power:SetValue(0)
            row.power:Hide()
            row:SetAlpha(self._oorEnabled and ROW_ALPHA_OOR or ROW_ALPHA_ACTIVE)
        else
            row._placeholder = true
            row.classFile = nil
            row.nameText:SetText("Enemy " .. tostring(row.index or ""))
            row.hpText:SetText("")
            row.hp:SetMinMaxValues(0, 1)
            row.hp:SetValue(0)
            row.hp:SetStatusBarColor(0.25, 0.25, 0.25, CLASS_ALPHA_OOR)
            row.power:SetMinMaxValues(0, 1)
            row.power:SetValue(0)
            row.power:Hide()
            row:SetAlpha(ROW_ALPHA_UNKNOWN)
        end
    end

    self:UpdateRowVisibilities()
end

function BGE:HandleUnitUpdate(unit, what, force)
    if not GetSetting("bgeEnabled", true) then return end
    if not IsInPVPInstance() then return end
    if not unit or not SafeUnitExists(unit) then return end

    if IsNameplateUnit(unit) then
        if not SafeUnitIsEnemyPlayer(unit) then return end
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
            if SafeUnitIsEnemyPlayer(unit) then
                self:HandlePlateAdded(unit)
            else
                self:HandlePlateRemoved(unit)
            end
        end
    end
end

function BGE:StartNameplateScanner()
    if self._nameplateTicker then return end
    self._nameplateTicker = C_Timer.NewTicker(0.25, function()
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
        if row and (row._seenIdentity or row._seenPlate) and not row._preview then
            local unit = row.unit
            if unit and SafeUnitExists(unit) and SafeUnitIsEnemyPlayer(unit) then
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
            elseif row._seenIdentity or row._seenPlate then
                local unit = row.unit
                local active = unit and SafeUnitExists(unit) and SafeUnitIsEnemyPlayer(unit)
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
    -- Preview uses normal strings so the left-side rotated spec lane is visible
    -- outside PvP. Live battleground specs may be secret display values; the
    -- live path still only passes them directly to the FontString.
    { name = "Druid",        classFile = "DRUID",       role = "HEALER",  specName = "Restoration" },
    { name = "Shaman",       classFile = "SHAMAN",      role = "HEALER",  specName = "Restoration" },
    { name = "Priest",       classFile = "PRIEST",      role = "HEALER",  specName = "Discipline"  },
    { name = "Demon Hunter", classFile = "DEMONHUNTER", role = "TANK",    specName = "Vengeance"   },
    { name = "Warrior",      classFile = "WARRIOR",     role = "DAMAGER", specName = "Arms"        },
    { name = "Paladin",      classFile = "PALADIN",     role = "DAMAGER", specName = "Retribution" },
    { name = "Rogue",        classFile = "ROGUE",       role = "DAMAGER", specName = "Subtlety"    },
    { name = "Druid",        classFile = "DRUID",       role = "DAMAGER", specName = "Balance"     },
    { name = "Mage",         classFile = "MAGE",        role = "DAMAGER", specName = "Frost"       },
    { name = "Warlock",      classFile = "WARLOCK",     role = "DAMAGER", specName = "Affliction"  },
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
            row.specName = rec.specName
            row.nameText:SetText(rec.name)
            UpdateSpecTextDisplay(row)
            row.hp:SetMinMaxValues(0, 100)
            row.hp:SetValue(82 - (i * 3 % 30))
            row.hpText:SetText(FormatHealthText(82 - (i * 3 % 30), 100, GetSetting("bgeHealthTextMode", 2)) or "")
            ApplyClassAlpha(row, CLASS_ALPHA_ACTIVE)
            if row.roleIcon then row.roleIcon:Hide() end
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

    local leftInset  = 2
    local rightInset = 4

    -- The spec label gets a fixed left lane. Its unrotated width becomes
    -- the vertical clipping length after rotation, so long spec names cut
    -- before they run past the bottom of the chosen row height.
    local specLaneW = math.floor(math.max(12, math.min(34, h * 0.33)))
    local specTextW = math.max(1, innerH - (SPEC_TEXT_SIDE_PADDING * 2))

    row.specText:ClearAllPoints()
    row.specText:SetWidth(specTextW)
    if row.specText.SetHeight then row.specText:SetHeight(specLaneW) end
    if row.specText.SetRotation then row.specText:SetRotation(SPEC_TEXT_ROTATION_RADIANS) end
    row.specText:SetPoint(
        "CENTER",
        row,
        "TOPLEFT",
        border + leftInset + (specLaneW * 0.5),
        -(border + SPEC_TEXT_SIDE_PADDING + (specTextW * 0.5))
    )
    row.specText:SetJustifyH("CENTER")
    if row.specText.SetJustifyV then row.specText:SetJustifyV("MIDDLE") end
    if row.specText.SetDrawLayer then row.specText:SetDrawLayer("OVERLAY", 7) end
    row.roleIcon:ClearAllPoints()
    row.roleIcon:Hide()

    local iconTex = row.achievIconTex
    local iconSize = 8
    local iconPad = 1
    local namePad = 2
    local iconOffset = iconTex and (iconSize + iconPad) or 0
    local nameLeft = leftInset + specLaneW + namePad + iconOffset

    row.nameText:ClearAllPoints()
    row.nameText:SetPoint("TOPLEFT", row.hp, "TOPLEFT", nameLeft, -1)
    row.nameText:SetJustifyH("LEFT")
    if row.nameText.SetDrawLayer then row.nameText:SetDrawLayer("OVERLAY", 7) end

    if iconTex then
        row.icon:ClearAllPoints()
        row.icon:SetTexture(iconTex)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
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
    row.hpText:SetWidth(math.max(0, w - (leftInset + rightInset + specLaneW + (border * 2))))
    row.hpText:SetJustifyH("CENTER")
    if row.hpText.SetDrawLayer then row.hpText:SetDrawLayer("OVERLAY", 7) end

    UpdateRoleDisplay(row)

    local nameMax = w - (nameLeft + rightInset + (border * 2))
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
evt:RegisterEvent("PLAYER_JOINED_PVP_MATCH")
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
evt:RegisterEvent("UPDATE_BATTLEFIELD_SCORE")
pcall(function() evt:RegisterEvent("UNIT_HEALTH_FREQUENT") end)
pcall(function() evt:RegisterEvent("UNIT_POWER_FREQUENT") end)

evt:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" then
        if IsInPVPInstance() or GetSetting("bgePreview", false) then
            CreateMainFrame()
            BGE:ApplySettings()
            BGE:SeedRosterFromScoreboard()
            BGE:ScanNameplates()
        end
        return
    end

    if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_JOINED_PVP_MATCH" or event == "ZONE_CHANGED_NEW_AREA" then
        BGE:UpdateMatchState()
        local inPvp = IsInPVPInstance()
        if inPvp or GetSetting("bgePreview", false) then
            CreateMainFrame()
        end
        BGE:ApplySettings()
        local isStartUp = false
        if inPvp and C_PvP and C_PvP.GetActiveMatchState and Enum and Enum.PvPMatchState then
            local ok, state = pcall(C_PvP.GetActiveMatchState)
            isStartUp = ok and state == Enum.PvPMatchState.StartUp
        end

        if isStartUp then
            local attempts = 0

            BGE._scoreboardSeeded = false
            BGE._scoreboardEnemyCount = nil
            BGE._scoreboardRoleCount = nil
            BGE._scoreboardSpecCount = nil
            BGE:RequestScoreboardData()
            BGE:StartNameplateScanner()

            local function TryStartupScoreboard()
                local bge = _G.RSTATS_BGE
                if not bge or not GetSetting("bgeEnabled", true) or not IsInPVPInstance() then return end

                local stillStartUp = false
                if C_PvP and C_PvP.GetActiveMatchState and Enum and Enum.PvPMatchState then
                    local ok, state = pcall(C_PvP.GetActiveMatchState)
                    stillStartUp = ok and state == Enum.PvPMatchState.StartUp
                end
                if not stillStartUp then return end

                local expected = tonumber(bge:ResolveExpectedRows()) or 10
                local have = tonumber(bge._scoreboardEnemyCount) or 0
                local specs = tonumber(bge._scoreboardSpecCount) or 0
                local specNeed = math.min(have, expected)
                local liveHP = 0

                for i = 1, expected do
                    local row = bge.rows and bge.rows[i]
                    if row and row._hasLiveHP then
                        liveHP = liveHP + 1
                    end
                end

                if have >= expected and specs >= specNeed and liveHP >= expected then return end

                attempts = attempts + 1

                bge:UpdateMatchState()
                bge:SeedRosterFromScoreboard()
                bge:WarmupTargetOneMissingHealthRow()
                bge:ScanNameplates()
                bge:UpdateRowVisibilities()

                have = tonumber(bge._scoreboardEnemyCount) or 0
                local specs = tonumber(bge._scoreboardSpecCount) or 0
                specNeed = math.min(have, expected)
                liveHP = 0

                for i = 1, expected do
                    local row = bge.rows and bge.rows[i]
                    if row and row._hasLiveHP then
                        liveHP = liveHP + 1
                    end
                end

                if attempts == 1 or attempts == 10 or attempts == 20 or attempts == 30 or attempts == 40 or attempts == 50 or attempts == 60 then
                    DPrint(
                        "HP_STARTUP_RETRY:" .. tostring(attempts),
                        "hp startup attempt=" .. tostring(attempts)
                        .. " rows=" .. tostring(have) .. "/" .. tostring(expected)
                        .. " specs=" .. tostring(specs) .. "/" .. tostring(specNeed)
                        .. " liveHP=" .. tostring(liveHP) .. "/" .. tostring(expected)
                    )
                end

                if (have < expected or specs < specNeed or liveHP < expected) and attempts < 60 then
                    bge:RequestScoreboardData()
                    C_Timer.After(0.5, TryStartupScoreboard)
                end
            end

            C_Timer.After(1, TryStartupScoreboard)
        else
            BGE:SeedRosterFromScoreboard()
            BGE:ScanNameplates()
        end
        
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
        BGE:SeedRosterFromScoreboard()
        BGE:ScanNameplates()
        return
    end

    if event == "PVP_MATCH_ACTIVE" then
        BGE:UpdateMatchState()
        BGE:PrimeRosterSlots()
        BGE:ScanNameplates()
        BGE:UpdateRowVisibilities()
        return
    end

    if event == "PVP_MATCH_COMPLETE" then
        BGE:UpdateMatchState()
        BGE:PrimeRosterSlots()
        BGE:SeedRosterFromScoreboard()
        BGE:ScanNameplates()
        BGE:UpdateRowVisibilities()
        return
    end

    if event == "UPDATE_BATTLEFIELD_SCORE" then
        BGE:SeedRosterFromScoreboard()
        BGE:ScanNameplates()
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
        if _G.RSTATS_BGE then
            _G.RSTATS_BGE._dbgLast = {}
        end
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
