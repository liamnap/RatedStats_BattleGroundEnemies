local addonName, RSTATS = ...
RSTATS = RSTATS or _G.RSTATS
-- Don't abort file load here; SavedVariables / RSTATS.Database may not be ready until PLAYER_LOGIN.

local BGE = {}
_G.RSTATS_BGE = BGE

local function IsInPVPInstance()
    -- BG-only: battlegrounds are instanceType "pvp".
    -- Arenas (including Solo Shuffle) are instanceType "arena" and must return false.
    if _G.IsInInstance then
        local ok, inInstance, instanceType = pcall(_G.IsInInstance)
        if ok and inInstance then
            if instanceType == "pvp" then
                return true
            end
            if instanceType == "arena" then
                return false
            end
        end
    end
    -- Fallback for older/odd clients
    if C_PvP and C_PvP.IsPVPMap then
        local ok, v = pcall(C_PvP.IsPVPMap)
        return ok and v or false
    end
    return false
end

BGE.rows = {}
BGE.previewRows = {}
BGE.maxPlates = 40

BGE._oorEnabled = false -- latch: enable out-of-range dimming only after gates open
BGE.rowByGuid = {}
BGE.rowByUnit = {}

-- Rated Stats theme colour (b69e86) for on-row text/icons (not class colour).
local RS_TEXT_R, RS_TEXT_G, RS_TEXT_B = 182/255, 158/255, 134/255

-- Visual state tuning
local ROW_ALPHA_ACTIVE   = 1.0
local ROW_ALPHA_OOR      = 0.55   -- out-of-range: noticeably dim
local CLASS_ALPHA_ACTIVE = 1.00
local CLASS_ALPHA_OOR    = 0.55   -- out-of-range: keep visible, just dim

local function InLockdown()
    return _G.InCombatLockdown and _G.InCombatLockdown()
end

-- If we had to skip anchoring due to lockdown, run it later.
BGE._anchorsDirty = false

-- Combat-safe: if we want to resize after combat, stash desired size.
BGE._pendingW = nil
BGE._pendingH = nil

-- Forward declare so debug helpers can call it before its definition.
local Scrub2
local GetSetting
local UpdateNameClipToHPFill
local SafeUnitGUID
local GetNameplateDisplayNames
local SafeStatusBarValues
local NormalizeFactionIndex
local UnitStillMatchesRow
local ClearUnitCollision
local CreateMainFrame

-- Debug (throttled)
BGE._dbgLast = {}

local function DebugAtMatchStartOnly()
    if not GetSetting("bgeDebug", false) then return false end
    if not IsInPVPInstance() then return false end
    if BGE and BGE._mode == "arena" then return false end
    -- Only during prep / opener. Once match has actually started, stop debug spam.
    if BGE and BGE.IsMatchStarted and BGE:IsMatchStarted() then return false end
    return true
end

local function DPrint(key, msg)
    if not GetSetting("bgeDebug", false) then return end
    if not DebugAtMatchStartOnly() then return end
    local now = GetTime()
    local last = BGE._dbgLast[key] or 0
    if (now - last) < 1.0 then return end
    BGE._dbgLast[key] = now
    print("|cffb69e86[RSTATS-BGE]|r " .. msg)
end

local function DPrintMissing(key, msg)
    if not GetSetting("bgeDebug", false) then return end
    if not DebugAtMatchStartOnly() then return end
    local now = GetTime()
    local last = BGE._dbgLast[key] or 0
    if (now - last) < 3.0 then return end
    BGE._dbgLast[key] = now
    print("|cffb69e86[RSTATS-BGE]|r " .. msg)
end



local function Bool01(v) return v and "1" or "0" end

local function SafeToString(v)
    local ok, s = pcall(function() return tostring(v) end)
    if not ok or type(s) ~= "string" then
        return nil
    end

    if _G.issecretvalue and _G.issecretvalue(s) then
        return nil
    end

    return s
end

local function SafeNonEmptyString(v)
    -- Never compare potentially-secret strings (e.g. s == ""); use len() in pcall.
    local s = SafeToString(v)
    if type(s) ~= "string" then return nil end
    local okLen, n = pcall(string.len, s)
    if not okLen or n == 0 then return nil end
    return s
end

local function HasNonEmptyString(v)
    local s = SafeNonEmptyString(v)
    return s and true or false
end

local function FontStringHasText(fs)
    if not fs or not fs.GetText then return false end
    local ok, t = pcall(fs.GetText, fs)
    if not ok then return false end
    local s = SafeNonEmptyString(t)
    return s and true or false
end

local function DebugUnitSnapshot(tag, unit)
    -- IMPORTANT: This function was doing heavy Unit* calls even when debug was OFF.
    -- Gate immediately so it becomes truly free outside debug.
    if not GetSetting or not GetSetting("bgeDebug", false) then return end

    local exists = UnitExists(unit)
    local isPlayer = exists and UnitIsPlayer(unit) or false
    local isEnemy = exists and UnitIsEnemy("player", unit) or false
    local okG, guid = false, nil
    if exists then
        okG, guid = pcall(UnitGUID, unit)
    end

    local okN, n, r = pcall(UnitName, unit)
    local okC, loc, cf = pcall(UnitClass, unit)
    local okR, rLoc, rTok, rID = pcall(UnitRace, unit)
    local okL, lvl = pcall(UnitLevel, unit)
    local okS, sex = pcall(UnitSex, unit)
    local okH, honor = pcall(UnitHonorLevel, unit)
    local fac = UnitFactionGroup and UnitFactionGroup(unit) or nil

    local nS   = SafeNonEmptyString(n)
    local rS   = SafeNonEmptyString(r)
    local cfS  = SafeNonEmptyString(cf)
    local locS = SafeNonEmptyString(loc)
    local guidS = SafeToString(guid)
    if guid and not guidS then guidS = "<secret>" end

    DPrint(tag .. ":" .. unit,
        tag .. " unit=" .. unit ..
        " exists=" .. Bool01(exists) ..
        " player=" .. Bool01(isPlayer) ..
        " enemy=" .. Bool01(isEnemy) ..
        " guid=" .. (guidS or "nil") ..
        " UnitName.ok=" .. Bool01(okN) ..
        " name=" .. (nS or "nil") ..
        " realm=" .. (rS or "nil") ..
        " UnitClass.ok=" .. Bool01(okC) ..
        " class=" .. (cfS or "nil") ..
        " classLoc=" .. (locS or "nil") ..
        " UnitRace.ok=" .. Bool01(okR) ..
        " raceID=" .. (rID and tostring(rID) or "nil") ..
        " UnitLevel.ok=" .. Bool01(okL) ..
        " lvl=" .. (lvl and tostring(lvl) or "nil") ..
        " UnitSex.ok=" .. Bool01(okS) ..
        " sex=" .. (sex and tostring(sex) or "nil") ..
        " UnitHonor.ok=" .. Bool01(okH) ..
        " honor=" .. (honor and tostring(honor) or "nil") ..
        " fac=" .. (fac or "nil")
    )
end

-- Debug helper: print what keys we actually seeded into rowByGuid.




local function IsNameplateUnit(unit)
    return type(unit) == "string" and unit:match("^nameplate%d+$") ~= nil
end

-- Arena uses arena unit tokens (arena1..arena5). Do NOT rely on nameplates in arena.
local function IsArenaUnit(unit)
    return type(unit) == "string" and unit:match("^arena%d+$") ~= nil
end

local function NameplateIndex(unit)
    if type(unit) ~= "string" then return nil end
    local n = unit:match("^nameplate(%d+)$") or unit:match("^arena(%d+)$")
    n = n and tonumber(n) or nil
    if not n or n < 1 then return nil end
    return n
end

local function ArenaIndex(unit)
    if type(unit) ~= "string" then return nil end
    local n = unit:match("^arena(%d+)$")
    n = n and tonumber(n) or nil
    if not n or n < 1 then return nil end
    return n
end

local function NameplateUnitFromIndex(i)
    return "nameplate" .. tostring(i)
end

local function ArenaUnitFromIndex(i)
    return "arena" .. tostring(i)
end

local function SafeUnitName(unit)
    local ok, name, realm = pcall(UnitName, unit)
    if not ok then return nil end
    -- Do NOT scrub. Validate via SafeNonEmptyString (stringify via pcall).
    local n = SafeNonEmptyString(name)
    if not n then return nil end
    -- realm is optional; keep it only if it can be stringified safely.
    local r = SafeNonEmptyString(realm)
    return n, r
end

local function SafeUnitFullName(unit)
    local n, r = SafeUnitName(unit)
    if not n then return nil, nil end
    if r and r ~= "" then
        return n .. "-" .. r, n
    end
    return n, n
end

local function NormalizeRaceID(raceID)
    raceID = tonumber(raceID) or 0
    -- Collapse known “multi-ID” races
    -- Pandaren: 24/26 collapse to 25
    if raceID == 24 or raceID == 26 then return 25 end
    -- Dracthyr: 70 collapse to 52
    if raceID == 70 then return 52 end
    -- Earthen: 84 collapse to 85
    if raceID == 84 then return 85 end
    -- Harronir/Haranir seen as 91 in some data; collapse to 86
    if raceID == 91 then return 86 end
    return raceID
end

local function GetUnitTrueFactionIndex(unit)
    local fac = UnitFactionGroup and UnitFactionGroup(unit) or nil
    local idx = NormalizeFactionIndex(fac)
        if UnitIsMercenary and UnitIsMercenary(unit) then
        idx = (idx == 0 and 1) or 0
    end
    return idx
end

local function SafeUnitClass(unit)
    local ok, loc, file = pcall(UnitClass, unit)
    if not ok then return nil, nil end
    -- Same rule: don't compare/inspect raw secret values; stringify first.
    local l = SafeToString(loc)
    local f = SafeToString(file)
    if type(l) ~= "string" then l = nil end
    if type(f) ~= "string" then f = nil end
    return l, f
end

NormalizeFactionIndex = function(v)
    -- 12.x secret values: never compare raw numeric values (they can be "secret").
    -- Convert safely to string first, then parse/compare.
    local s = SafeToString(v)
    if type(s) ~= "string" then return nil end

    local n = tonumber(s)
    if n == 0 or n == 1 then return n end
    if s == "Alliance" then return 1 end
    if s == "Horde" then return 0 end
    return nil
end





local function SafePlateBars(unit)
    if not (_G.C_NamePlate and _G.C_NamePlate.GetNamePlateForUnit) then return nil, nil end
    local okP, plate = pcall(_G.C_NamePlate.GetNamePlateForUnit, unit)
    if not okP or not plate or not plate.UnitFrame then return nil, nil end
    return plate, plate.UnitFrame
end

ClearUnitCollision = function(self, unit, keepRow)
    if not self or not self.rowByUnit or not unit then return end
    local other = self.rowByUnit[unit]
    if not other or other == keepRow then return end

    -- Unmap the other row from this recycled unit token (nameplateN)
    if other.unit == unit then
        other.unit = nil
    else
        -- Defensive: even if out-of-sync, we still drop secure/unit binding for safety.
        other.unit = nil
    end

    -- IMPORTANT: clear multi-source identity for this token
    if other.UnitIDs then
        if other.UnitIDs.Nameplate == unit then
            other.UnitIDs.Nameplate = nil
        end
        -- Defensive: if someone ever stored unit.."target" incorrectly here, drop it too.
        local derivedTarget = unit .. "target"
        if other.UnitIDs.NameplateTarget == derivedTarget then
            other.UnitIDs.NameplateTarget = nil
        end
    end

    other.unitID = nil
    other._unitIDKind = nil
    if self.ResolveEnemyPrimaryUnitID then
        self:ResolveEnemyPrimaryUnitID(other)
    end

    -- Clear cached plate bars (frames get recycled)
    other._barsUnit = nil
    other._hpSB = nil
    other._pwrSB = nil
    other._hpSBAt = nil
    other._pwrSBAt = nil

    -- Remove reverse mapping
    if self.rowByUnit[unit] == other then
        self.rowByUnit[unit] = nil
    end

    if not InLockdown() then
        pcall(other.SetAttribute, other, "unit", nil)
    end

    other._outOfRange = true
    ApplyClassAlpha(other, CLASS_ALPHA_OOR)
    other:SetAlpha(other._seenIdentity and ROW_ALPHA_OOR or 0)
end

-- Find and return the actual StatusBar used for health on this nameplate UnitFrame.
-- This is expensive; callers should cache the returned bar per-row/per-unit.
local function FindPlateHealthStatusBar(unit)
    local _, uf = SafePlateBars(unit)
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
    if uf.GetChildren then
        local kids = { uf:GetChildren() }
        for i = 1, #kids do
            local k = kids[i]
            if k and k.GetObjectType then
                local okOT, ot = pcall(k.GetObjectType, k)
                if okOT and ot == "StatusBar" then
                    local cur, maxv = SafeStatusBarValues(k)
                    if cur and maxv then return k end
                end
            end
        end
    end
    return nil
end

-- Find and return the StatusBar used for power, plus a stable color for it.
-- This is expensive; callers should cache the returned bar per-row/per-unit.
local function FindPlatePowerStatusBar(unit)
    local _, uf = SafePlateBars(unit)
    if not uf then return nil end

    local function ColorFromBar(sb)
        local r, g, b = 0.0, 0.55, 1.0
        if sb and sb.GetStatusBarColor then
            local okC, cr, cg, cb = pcall(sb.GetStatusBarColor, sb)
            if okC and type(cr)=="number" and type(cg)=="number" and type(cb)=="number" then
                r, g, b = cr, cg, cb
            end
        end
        return r, g, b
    end

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
        if cur and maxv then
            local r, g, b = ColorFromBar(sb)
            return sb, r, g, b
        end
    end

    local function ScanChildren(parent)
        if not (parent and parent.GetChildren) then return nil end
        local kids = { parent:GetChildren() }
        for i = 1, #kids do
            local k = kids[i]
            if k and k.GetObjectType then
                local okOT, ot = pcall(k.GetObjectType, k)
                if okOT and ot == "StatusBar" then
                    if k ~= uf.healthBar and k ~= uf.castBar then
                        local cur, maxv = SafeStatusBarValues(k)
                        if cur and maxv then
                            local r, g, b = ColorFromBar(k)
                            return k, r, g, b
                        end
                    end
                end
            end
        end
        return nil
    end

    local sb, r, g, b = ScanChildren(uf)
    if sb then return sb, r, g, b end
    sb, r, g, b = ScanChildren(uf.PowerBarsContainer)
    if sb then return sb, r, g, b end
    return nil
end

SafeStatusBarValues = function(sb)
    if not sb or not sb.GetValue or not sb.GetMinMaxValues then return nil, nil end
    local okV, v = pcall(sb.GetValue, sb)
    if not okV or type(v) ~= "number" then return nil, nil end
    local okMM, mn, mx = pcall(sb.GetMinMaxValues, sb)
    if not okMM or type(mx) ~= "number" then return nil, nil end
    
    local isSecretV = (_G.issecretvalue and _G.issecretvalue(v)) or false
    local isSecretM = (_G.issecretvalue and _G.issecretvalue(mx)) or false
    return v, mx, (isSecretV or isSecretM)
end

-- Derive an approximate percent from a StatusBar's fill texture width.
-- This avoids doing math on restricted/secret health values on 12.0+/Midnight.
local function SafePercentFromStatusBarFill(sb)
    if not sb or not sb.GetWidth or not sb.GetStatusBarTexture then return nil end
    local okW, w = pcall(sb.GetWidth, sb)
    if not okW or type(w) ~= "number" then return nil end
    if _G.issecretvalue and _G.issecretvalue(w) then return nil end
    if w <= 0 then return nil end

    local okTex, tex = pcall(sb.GetStatusBarTexture, sb)
    if not okTex or not tex or not tex.GetWidth then return nil end
    local okTW, tw = pcall(tex.GetWidth, tex)
    if not okTW or type(tw) ~= "number" then return nil end
    if _G.issecretvalue and _G.issecretvalue(tw) then return nil end

    local pct = math.floor((tw / w) * 100 + 0.5)
    if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
    return pct
end

-- Prefer Blizzard-provided numeric strings on the nameplate health StatusBar.
local function SafePlateHealthNumericText(sb)
    if not sb then return nil end

    local fs = sb.TextString or sb.Text or sb.RightText or sb.LeftText
    if not fs or not fs.GetText then return nil end

    local okT, t = pcall(fs.GetText, fs)
    if not okT or type(t) ~= "string" then return nil end

    return t
end

local function SafePlateHealth(unit)
    local _, uf = SafePlateBars(unit)
    if not uf then return nil, nil end
    -- Try common fields across default Blizzard + custom nameplates.
    local candidates = {
        uf.healthBar,
        uf.HealthBar,
        (uf.HealthBarsContainer and uf.HealthBarsContainer.healthBar),
        (uf.healthBar and uf.healthBar.bar),
        (uf.healthBar and uf.healthBar.healthBar),
    }
    for i = 1, #candidates do
        local cur, maxv, secret = SafeStatusBarValues(candidates[i])
        if cur and maxv then return cur, maxv, secret end
    end
    -- Last resort: scan child frames for the first StatusBar with values.
    if uf.GetChildren then
        local kids = { uf:GetChildren() }
        for i = 1, #kids do
            local k = kids[i]
            if k and k.GetObjectType then
                local okOT, ot = pcall(k.GetObjectType, k)
                if okOT and ot == "StatusBar" then
                    local cur, maxv, secret = SafeStatusBarValues(k)
                    if cur and maxv then return cur, maxv, secret end
                end
            end
        end
    end
    return nil, nil
end

local function SafePlatePower(unit)
    local _, uf = SafePlateBars(unit)
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

    local function ColorFromBar(sb)
        local r, g, b = 0.0, 0.55, 1.0
        if sb and sb.GetStatusBarColor then
            local okC, cr, cg, cb = pcall(sb.GetStatusBarColor, sb)
            if okC and type(cr)=="number" and type(cg)=="number" and type(cb)=="number" then
                r, g, b = cr, cg, cb
            end
        end
        return r, g, b
    end

    for i = 1, #candidates do
        local sb = candidates[i]
        local cur, maxv, secret = SafeStatusBarValues(sb)
        if cur and maxv then
            local r, g, b = ColorFromBar(sb)
            return cur, maxv, r, g, b
        end
    end

    local function ScanChildren(parent)
        if not (parent and parent.GetChildren) then return nil end
        local kids = { parent:GetChildren() }
        for i = 1, #kids do
            local k = kids[i]
            if k and k.GetObjectType then
                local okOT, ot = pcall(k.GetObjectType, k)
                if okOT and ot == "StatusBar" then
                    -- Skip obvious non-power bars
                    if k ~= uf.healthBar and k ~= uf.castBar then
                        local cur, maxv = SafeStatusBarValues(k)
                        if cur and maxv then
                            local r, g, b = ColorFromBar(k)
                            return cur, maxv, r, g, b
                        end
                    end
                end
            end
        end
        return nil
    end

    local cur, maxv, r, g, b = ScanChildren(uf)
    if cur and maxv then return cur, maxv, r, g, b end
    cur, maxv, r, g, b = ScanChildren(uf.PowerBarsContainer)
    if cur and maxv then return cur, maxv, r, g, b end

    return nil
end

local function SafeUnitHealth(unit)
    local ok1, cur  = pcall(UnitHealth, unit)
    local ok2, maxv = pcall(UnitHealthMax, unit)
    if not ok1 or not ok2 then return nil, nil end
    -- 12.0+/Midnight: UnitHealth/UnitHealthMax can return "secret" numbers.
    -- Do NOT compare, format, or do math on them here. Just return the values.
    return cur, maxv
end

local function SafeUnitPower(unit)
    local okT, pType, pToken, altR, altG, altB = pcall(UnitPowerType, unit)
    if not okT then return nil end

    local ok1, cur = pcall(UnitPower, unit, pType)
    local ok2, maxv = pcall(UnitPowerMax, unit, pType)
    if not ok1 or not ok2 then return nil end
    -- 12.0+/Midnight: UnitPower/UnitPowerMax can return "secret" numbers.
    -- Do NOT compare or do math on them here. Just return the values.

    local r, g, b
    if type(altR) == "number" and type(altG) == "number" and type(altB) == "number" then
        r, g, b = altR, altG, altB
    elseif type(pToken) == "string" and PowerBarColor and PowerBarColor[pToken] then
        r, g, b = PowerBarColor[pToken].r, PowerBarColor[pToken].g, PowerBarColor[pToken].b
    elseif PowerBarColor and PowerBarColor["MANA"] then
        r, g, b = PowerBarColor["MANA"].r, PowerBarColor["MANA"].g, PowerBarColor["MANA"].b
    else
        r, g, b = 0.0, 0.55, 1.0
    end

    return cur, maxv, r, g, b
end

local function GetClassRGB(classFile)
    if not classFile then return 0, 0, 0 end

    if C_ClassColor and C_ClassColor.GetClassColor then
        local c = C_ClassColor.GetClassColor(classFile)
        if c and c.GetRGB then
            return c:GetRGB()
        end
    end

    if RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
        local c = RAID_CLASS_COLORS[classFile]
        return c.r, c.g, c.b
    end

    return 0, 0, 0
end





local function GetPlayerDB()
    if type(_G.LoadData) == "function" then
        pcall(_G.LoadData)
    end

    local RS = _G.RSTATS
    if not RS or not RS.Database then return nil end

    local name = UnitName("player")
    local realm = GetRealmName and GetRealmName() or nil
    local key = (name and realm and (name .. "-" .. realm)) or name
    if not key then return nil end

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
    -- Outside PvP, you can only preview one profile at a time.
    -- Pick the first enabled preview toggle in a deterministic order.
    if not db or not db.settings then
        return "bgeRated"
    end
    local s = db.settings
    if s.bgeRatedPreview then return "bgeRated" end
    if s.bge10Preview then return "bge10" end
    if s.bge15Preview then return "bge15" end
    if s.bgeLargePreview then return "bgeLarge" end
    return "bgeRated"
end

GetSetting = function(key, default)
    local db = GetPlayerDB()
    if not db then return default end

    local suffix = BGE_PROFILE_SUFFIX[key]
    if suffix then
        -- Preview toggle is strictly "outside PvP".
        -- Never let it override real BG behaviour.
        if key == "bgePreview" and IsInPVPInstance() then
            return false
        end

        local prefix = BGE._profilePrefix
        if not IsInPVPInstance() then
            -- Preview profile can change while you're in PvE (via Settings).
            -- Always re-resolve; do not rely on a cached prefix being "good enough".
            prefix = ResolvePreviewProfilePrefix(db)
            BGE._profilePrefix = prefix
        end

        if prefix then
            local v2 = db.settings[prefix .. suffix]
            if v2 ~= nil then
                return v2
            end
        end

        -- Legacy fallback
        local vLegacy = db.settings[key]
        if vLegacy ~= nil then
            return vLegacy
        end
        return default
    end

    local v = db.settings[key]
    if v == nil then return default end
    return v
end

local function SetSetting(key, value)
    local db = GetPlayerDB()
    if not db then return end
    db.settings[key] = value
end

-- =============================================================
-- Hover anchor button + team tint (container background)
-- =============================================================

BGE._anchorHover = 0
BGE._anchorHidePending = false
BGE._dropdownMenu = nil

local function GetEnemyFactionIndex()
-- Prefer the match team when available (mercenary-safe).
    if _G.C_PvP and _G.C_PvP.GetActiveMatchFaction then
        local okF, f = pcall(_G.C_PvP.GetActiveMatchFaction)
        if okF and type(f) == "number" then
            local myIdx = NormalizeFactionIndex(f)
            return (myIdx == 0 and 1) or 0
        end
    end

    -- Next best: Battlefield API (can be available in instanced PvP).
    if _G.GetBattlefieldArenaFaction then
        local ok, fi = pcall(_G.GetBattlefieldArenaFaction)
        if ok and type(fi) == "number" then
            return (fi + 1) % 2
        end
    end

    -- Fallback: use player's true match faction (mercenary-safe), then invert.
    local myIdx = GetUnitTrueFactionIndex("player")
    return (myIdx == 0 and 1) or 0
end

function BGE:GetEnemyTeamColorRGB()
    local enemyFactionIndex = GetEnemyFactionIndex()

    -- If Blizzard's PvP UI is loaded, reuse its team colors.
    if _G.PVPMatchStyle and _G.PVPMatchStyle.GetTeamColor then
        local ok, c = pcall(_G.PVPMatchStyle.GetTeamColor, enemyFactionIndex, false)
        if ok and c and c.GetRGBA then
            local r, g, b = c:GetRGBA()
            if type(r) == "number" and type(g) == "number" and type(b) == "number" then
                return r, g, b
            end
        end
    end

    -- Hard fallback (matches Blizzard defaults closely)
    if enemyFactionIndex == 0 then
        -- Horde (red)
        return 1.0, 0.08, 0.08
    end
    -- Alliance (blue)
    return 0.08, 0.45, 1.0
end

function BGE:UpdateFrameTeamTint()
    if not self.frame or not self.frame.bg then return end


    local preview = GetSetting("bgePreview", false)
    if preview then
        -- Preview mode: tint as the *opposing* faction of the current player.
        -- (Not match-based, because preview can be used out of instance.)
        local oppIdx
        local fac = UnitFactionGroup and UnitFactionGroup("player") or nil
        if fac == "Horde" then
            oppIdx = 1 -- Alliance
        elseif fac == "Alliance" then
            oppIdx = 0 -- Horde
        end

        if oppIdx ~= nil and _G.PVPMatchStyle and _G.PVPMatchStyle.GetTeamColor then
            local ok, c = pcall(_G.PVPMatchStyle.GetTeamColor, oppIdx, false)
            if ok and c and c.GetRGBA then
                local r, g, b = c:GetRGBA()
                if type(r) == "number" and type(g) == "number" and type(b) == "number" then
                    self.frame.bg:SetColorTexture(r, g, b, 0.20)
                    return
                end
            end
        end

        -- Hard fallback if PVPMatchStyle isn't available.
        if oppIdx == 1 then
            self.frame.bg:SetColorTexture(0.08, 0.45, 1.0, 0.20) -- Alliance blue
        else
            self.frame.bg:SetColorTexture(1.0, 0.08, 0.08, 0.20) -- Horde red
        end
        return
    end

    if not IsInPVPInstance() then
        self.frame.bg:SetColorTexture(0, 0, 0, 0.0)
        return
    end

    local r, g, b = self:GetEnemyTeamColorRGB()
    -- Subtle tint only (still "transparent" like the minimap menu background)
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

    if self._anchorHover > 0 then return end
    -- If a context menu is open from the anchor tab, keep it visible.
    if self._menuOpen then return end
    if self._anchorHidePending then return end

    self._anchorHidePending = true
    if C_Timer and C_Timer.After then
        C_Timer.After(0.15, function()
            local bge = _G.RSTATS_BGE
            if not bge then return end
            bge._anchorHidePending = false
            if (bge._anchorHover or 0) == 0 and (not bge._menuOpen) and bge.frame and bge.frame.anchorTab then
                bge.frame.anchorTab:Hide()
            end
        end)
    else
        self._anchorHidePending = false
        if self.frame and self.frame.anchorTab then
            self.frame.anchorTab:Hide()
        end
    end
end

function BGE:OpenRatedStatsSettings()
    -- Prefer Rated Stats exposing an in-game settings/open function.
    if type(_G.RSTATS_OpenSettings) == "function" then
        pcall(_G.RSTATS_OpenSettings)
        return
    end

    if _G.RSTATS and type(_G.RSTATS.OpenSettings) == "function" then
        pcall(_G.RSTATS.OpenSettings, _G.RSTATS)
        return
    end

    -- Settings API (Retail): try to jump to Rated Stats category by name.
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

        -- If we can't jump directly, at least open Settings so the user is one click away.
        if _G.C_SettingsUtil and _G.C_SettingsUtil.OpenSettingsPanel then
            pcall(_G.C_SettingsUtil.OpenSettingsPanel)
            return
        end
    end

    -- Legacy fallback (older Interface Options frame)
    if _G.InterfaceOptionsFrame_OpenToCategory then
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

    -- Hold the tab open while the menu is open, otherwise the menu closes when the tab hides.
    self._menuOpen = true
    if self.AnchorHoverBegin then
        self:AnchorHoverBegin()
    end

    local function ReleaseMenuHold()
        local bge = _G.RSTATS_BGE
        if not bge then return end
        if not bge._menuOpen then return end
        bge._menuOpen = false
        if bge.AnchorHoverEnd then
            bge:AnchorHoverEnd()
        end
    end

    -- Modern retail context menu (preferred).
    if _G.MenuUtil and type(_G.MenuUtil.CreateContextMenu) == "function" then
        local menu = _G.MenuUtil.CreateContextMenu(owner, function(_, root)
            root:CreateTitle("Rated Stats - BGE")
            root:CreateCheckbox(
                "Lock",
                function() return GetSetting("bgeLocked", true) end,
                function() ToggleLock() end
            )
            root:CreateButton("Settings", function() self:OpenRatedStatsSettings() end)
        end)
        if menu and menu.HookScript then
            menu:HookScript("OnHide", ReleaseMenuHold)
        else
            -- Failsafe: if we didn't get a frame back, don't trap the tab forever.
            ReleaseMenuHold()
        end
        return
    end

    -- Fallback for older builds: EasyMenu / UIDropDownMenu
    if not _G.EasyMenu then return end
    if not self._dropdownMenu then
        self._dropdownMenu = CreateFrame("Frame", "RatedStats_BGE_Dropdown", UIParent, "UIDropDownMenuTemplate")
    end

    local lockedNow = GetSetting("bgeLocked", true)
    local menu = {
        { text = "Rated Stats - BGE", isTitle = true, notCheckable = true },
        {
            text = "Lock",
            isNotRadio = true,
            keepShownOnClick = true,
            checked = lockedNow,
            func = ToggleLock,
        },
        { text = "Settings", notCheckable = true, func = function() self:OpenRatedStatsSettings() end },
    }
    _G.EasyMenu(menu, self._dropdownMenu, owner, 0, 0, "MENU")

    -- EasyMenu actually shows DropDownList1; hook its hide to release the tab hold.
    if _G.DropDownList1 and _G.DropDownList1.HookScript then
        _G.DropDownList1:HookScript("OnHide", ReleaseMenuHold)
    else
        ReleaseMenuHold()
    end
end

local function IsInArenaInstance()
    if _G.IsInInstance then
        local ok, inInstance, instanceType = pcall(_G.IsInInstance)
        if ok and inInstance and instanceType == "arena" then
            return true
        end
    end
    return false
end

local __achievWarnedMissingAPI = false

local function GetIconTextureForEnemyName(fullName, baseName)
    if not GetSetting("bgeShowAchievIcon", false) then return nil end

    local fn = (type(fullName) == "string" and fullName ~= "") and fullName or nil
    local bn = (type(baseName) == "string" and baseName ~= "") and baseName or nil
    if not fn and not bn then return nil end

    -- Optional cross-addon API.
    -- Prefer fullName (Name-Realm) to avoid collisions; fall back to baseName only if needed.
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
        if ok and type(iconPath) == "string" and iconPath ~= "" then
            return iconPath, highestText, iconTint
        end
    end

    if bn then
        local ok, iconPath, highestText, iconTint = pcall(api, bn)
        if ok and type(iconPath) == "string" and iconPath ~= "" then
            return iconPath, highestText, iconTint
        end
    end

    return nil
end

local function MakeRow(parent, plateIndex)
    -- Secure unit button: click-to-target "nameplateX" (Midnight-safe path).
    local row = CreateFrame("Button", nil, parent, "SecureActionButtonTemplate")
    -- IMPORTANT: Never Hide/Show secure buttons once created.
    -- Visibility is driven via alpha only to avoid ADDON_ACTION_BLOCKED in combat.
    row:SetAlpha(0)
    row:Show()
    -- IMPORTANT: do not toggle EnableMouse later; it can be blocked under lockdown.
    row:EnableMouse(true)
    row:RegisterForClicks(GetCVarBool("ActionButtonUseKeyDown") and "AnyDown" or "AnyUp")
    row:SetAttribute("type1", nil)
    row:SetAttribute("macrotext", nil)
    row.plateIndex = nil

    -- PostClick: keep secure macro targeting intact, then apply selection highlight.
    row:HookScript("PostClick", function(self, button)
        local bge = _G.RSTATS_BGE
        if bge and bge.SetSelectedRow then
            bge:SetSelectedRow(self)
        end
    end)

        row:HookScript("PostClick", function(self)
        local bge = _G.RSTATS_BGE
        if bge then
            bge:SetSelectedRow(self)
        end
    end)

    -- Blizzard-like backing (opaque dark) + 1px border
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints(true)
    row.bg:SetTexture("Interface\\RaidFrame\\Raid-Bar-Hp-Bg")
    row.bg:SetVertexColor(0.10, 0.10, 0.10, 0.95)

    row.borderTop = row:CreateTexture(nil, "BORDER")
    row.borderTop:SetColorTexture(0, 0, 0, 0.95)
    row.borderTop:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.borderTop:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    row.borderTop:SetHeight(1)

    row.borderBottom = row:CreateTexture(nil, "BORDER")
    row.borderBottom:SetColorTexture(0, 0, 0, 0.95)
    row.borderBottom:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    row.borderBottom:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    row.borderBottom:SetHeight(1)

    row.borderLeft = row:CreateTexture(nil, "BORDER")
    row.borderLeft:SetColorTexture(0, 0, 0, 0.95)
    row.borderLeft:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.borderLeft:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    row.borderLeft:SetWidth(1)

    row.borderRight = row:CreateTexture(nil, "BORDER")
    row.borderRight:SetColorTexture(0, 0, 0, 0.95)
    row.borderRight:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    row.borderRight:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    row.borderRight:SetWidth(1)

    -- Blizzard-like selection/target highlight (1px gold border)
    row.selectTop = row:CreateTexture(nil, "OVERLAY")
    row.selectTop:SetColorTexture(1.00, 0.82, 0.00, 1.00)
    row.selectTop:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.selectTop:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    row.selectTop:SetHeight(1)
    row.selectTop:Hide()

    row.selectBottom = row:CreateTexture(nil, "OVERLAY")
    row.selectBottom:SetColorTexture(1.00, 0.82, 0.00, 1.00)
    row.selectBottom:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    row.selectBottom:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    row.selectBottom:SetHeight(1)
    row.selectBottom:Hide()

    row.selectLeft = row:CreateTexture(nil, "OVERLAY")
    row.selectLeft:SetColorTexture(1.00, 0.82, 0.00, 1.00)
    row.selectLeft:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.selectLeft:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    row.selectLeft:SetWidth(1)
    row.selectLeft:Hide()

    row.selectRight = row:CreateTexture(nil, "OVERLAY")
    row.selectRight:SetColorTexture(1.00, 0.82, 0.00, 1.00)
    row.selectRight:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    row.selectRight:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    row.selectRight:SetWidth(1)
    row.selectRight:Hide()

    row.hp = CreateFrame("StatusBar", nil, row)
    row.hp:SetStatusBarTexture("Interface\\RaidFrame\\Raid-Bar-Hp-Fill")
    row.hp:SetMinMaxValues(0, 1)
    row.hp:SetValue(0)
    row.hp:SetStatusBarColor(0.10, 0.90, 0.10, 1.00)

    row.power = CreateFrame("StatusBar", nil, row)
    row.power:SetStatusBarTexture("Interface\\RaidFrame\\Raid-Bar-Resource-Fill")
    row.power:SetMinMaxValues(0, 1)
    row.power:SetValue(0)
    row.power:SetStatusBarColor(0.0, 0.55, 1.0, 0.90)
    row.power:Hide()

    -- IMPORTANT: Put overlay regions ON the HP bar frame so the bar can't draw over them.
    row.roleIcon = row.hp:CreateTexture(nil, "OVERLAY")
    row.roleIcon:SetTexCoord(0, 1, 0, 1)
    row.roleIcon:Hide()

    row.icon = row.hp:CreateTexture(nil, "OVERLAY")
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.icon:Hide()

    -- Mouse hit area for the achievement icon (textures are not reliable for scripts)
    row.iconHit = CreateFrame("Frame", nil, row)
    row.iconHit:EnableMouse(true)
    row.iconHit:SetPropagateMouseClicks(true)
    row.iconHit:Hide()
    row.iconHit.row = row

    row.iconHit:SetScript("OnEnter", function(self)
        local r = self.row
        if not r or not r.achievIconTex then return end

        -- Prefer fullName split (Name-Realm). Realm can contain hyphens, so split on first only.
        local name, realm
        if type(r.fullName) == "string" then
            name, realm = r.fullName:match("^([^-]+)%-(.+)$")
        end
        name = name or r.name
        realm = realm or GetRealmName()
        if not name or name == "" then return end

        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()

        if type(_G.RSTATS_Achiev_AddAchievementInfoToTooltip) == "function" then
            _G.RSTATS_Achiev_AddAchievementInfoToTooltip(GameTooltip, name, realm)
        else
            -- fallback (shouldn't happen once Achiev is updated)
            GameTooltip:AddLine((r.fullName and r.fullName ~= "" and r.fullName) or name, 1, 1, 1)
            if r.achievText and r.achievText ~= "" then
                GameTooltip:AddLine(r.achievText, 0.9, 0.9, 0.9, true)
            end
            GameTooltip:Show()
        end
    end)
    row.iconHit:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

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

    row.guid = nil
    row.unit = nil -- secure click bind; only real nameplate units belong here
	row.unitID = nil -- primary read source for HP/PWR/range
	row.UnitIDs = {
		Nameplate = nil,
		Target = nil,
		Focus = nil,
		Mouseover = nil,
		SoftEnemy = nil,
		GroupTarget = nil,
		NameplateTarget = nil,
	}
    row.name = nil
    row.fullName = nil
    row.achievIconTex = nil
    row.classFile = nil
    row.role = nil
    row.specID = nil
    row._preview = false

    -- Show the top-left anchor button when hovering any row.
    row:HookScript("OnEnter", function()
        local bge = _G.RSTATS_BGE
        if bge and bge.AnchorHoverBegin then
            bge:AnchorHoverBegin()
        end
    end)
    row:HookScript("OnLeave", function()
        local bge = _G.RSTATS_BGE
        if bge and bge.AnchorHoverEnd then
            bge:AnchorHoverEnd()
        end
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
    if not UnitExists("target") then
        self:SetSelectedRow(nil)
        return
    end

    for _, row in ipairs(self.rows or {}) do
        if row and not row._preview then
            local u = row.unit
            if type(u) == "string" and u ~= "" then
                local okE, ex = pcall(UnitExists, u)
                if okE and ex == true then
                    local okI, same = pcall(UnitIsUnit, "target", u)
                    if okI and same == true then
                        self:SetSelectedRow(row)
                        return
                    end
                end
            end
        end
    end

    local guid = SafeUnitGUID("target")
    if type(guid) == "string" and guid ~= "" and self.rowByGuid then
        local ok, hit = pcall(function() return self.rowByGuid[guid] end)
        if ok and hit then
            self:SetSelectedRow(hit)
            return
        end
    end

    self:SetSelectedRow(nil)
end

function BGE:EnsureSecureRows(want)
    if not self.frame then return end
    if InLockdown() then
        -- Can't create secure buttons in combat.
        self._rowsDirty = true
        return
    end

    if type(want) ~= "number" or want < 1 then want = 1 end
    if want > self.maxPlates then want = self.maxPlates end

    local have = #self.rows
    if have >= want then return end

    for i = have + 1, want do
        self.rows[i] = MakeRow(self.frame, i)
        self.rows[i]:SetAlpha(0)
    end
end

local function ApplyClassAlpha(row, a)
    if not row or not row.hp then return end
    if row.classFile then
        local r, g, b = GetClassRGB(row.classFile)
        row.hp:SetStatusBarColor(r, g, b, a)
    else
        row.hp:SetStatusBarColor(0.10, 0.90, 0.10, a)
    end
end

-- Mode: "bg" uses nameplateX, "arena" uses arena1..arena5
BGE._mode = "bg"
BGE._modeDirty = false
BGE.arenaMax = 5
-- What unit tokens the secure buttons are currently using (can lag behind _mode under lockdown).
BGE._secureMode = "bg"

function BGE:ApplyMode()
    local want = IsInArenaInstance() and "arena" or "bg"
    -- Always update display-mode immediately (layout/visibility logic uses this).
    self._mode = want

    -- Changing secure attributes requires out-of-combat.
    if InLockdown() then
        self._modeDirty = true
        return
    end
    self._modeDirty = false

    -- If secure buttons are already correct, nothing to do.
    if self._secureMode == want then return end
    self._secureMode = want

    for i = 1, self.maxPlates do
        local row = self.rows[i]
        if row then
            if want == "arena" and i <= self.arenaMax then
                row:SetAttribute("unit", ArenaUnitFromIndex(i))
            else
                                row:SetAttribute("unit", nil)
            end
        end
    end
end

local PREVIEW_ROSTER = {
    { name = "Druid",        classFile = "DRUID" },
    { name = "Shaman",       classFile = "SHAMAN" },
    { name = "Priest",       classFile = "PRIEST" },
    { name = "Demon Hunter", classFile = "DEMONHUNTER" },
    { name = "Warrior",      classFile = "WARRIOR" },
    { name = "Paladin",      classFile = "PALADIN" },
    { name = "Rogue",        classFile = "ROGUE" },
    { name = "Hunter",       classFile = "HUNTER" },
    { name = "Mage",         classFile = "MAGE" },
    { name = "Warlock",      classFile = "WARLOCK" },
}

function BGE:ClearPreviewRows()
    for _, row in ipairs(self.previewRows) do
        row._preview = false
        self:ReleaseRow(row)
    end
    wipe(self.previewRows)
end

local function FormatHealthText(cur, maxv, mode)
    if mode == 2 then
        return cur .. "/" .. maxv
    elseif mode == 3 then
        local pct = math.floor((cur / maxv) * 100 + 0.5)
        return pct .. "%"
    end
    return tostring(cur)
end













function BGE:IsMatchStarted()
    if not (C_PvP and C_PvP.GetActiveMatchState) then return false end
    local ok, state = pcall(C_PvP.GetActiveMatchState)
    if not ok or type(state) ~= "number" then return false end
    if Enum and Enum.PvPMatchState then
        local engaged = Enum.PvPMatchState.Engaged or 3
        return state == engaged
    end
    -- Fallback: Engaged is 3 in the known enum sequence
    return state == 3
end

function BGE:UpdateMatchState()
    local wasStarted = self._matchStarted
    self._matchStarted = self:IsMatchStarted()

    if self._matchStarted then
        self._oorEnabled = true
        if not wasStarted and self.EngagedNameplateSweep then
            self:EngagedNameplateSweep()
        end
    else
        self._oorEnabled = false
    end

    if not IsInPVPInstance() then
        self._matchStarted = false
        self._oorEnabled = false
    end
end

function BGE:EnsurePreviewRows()
    if IsInPVPInstance() then
        self:ClearPreviewRows()
        return
    end

    if not GetSetting("bgePreview", false) then
        self:ClearPreviewRows()
        return
    end

    local want = GetSetting("bgePreviewCount", 8)
    if type(want) ~= "number" or want < 1 then want = 1 end
    if want > 10 then want = 10 end
    if want > #PREVIEW_ROSTER then want = #PREVIEW_ROSTER end

    for i = 1, want do
        local rec = PREVIEW_ROSTER[i]
        local row = self.rows[i]
        if not row then return end
        self.previewRows[i] = row

        row._preview = true
        row.unit = nil
        row.unitID = nil
        row._unitIDKind = nil
        row.name = rec.name
        row.fullName = nil
        row.achievIconTex = nil
        row.achievText = nil
        row.achievTint = nil
        row.classFile = rec.classFile
        row.role = nil
        row.specID = nil
        row.guid = nil
        row._seenIdentity = true
        row._outOfRange = false

        local r, g, b = GetClassRGB(rec.classFile)
        row.bg:SetColorTexture(0, 0, 0, 0.35)
        row.hp:SetStatusBarColor(r, g, b, 0.85)

        row.hp:SetMinMaxValues(0, 100)
        local v = 82 - (i * 3 % 30)
        row.hp:SetValue(v)
        local mode = GetSetting("bgeHealthTextMode", 2)
        row.hpText:SetText(FormatHealthText(v, 100, mode))
        row.nameText:SetText(rec.name)
        row.nameText:SetTextColor(RS_TEXT_R, RS_TEXT_G, RS_TEXT_B)
        row.hpText:SetTextColor(RS_TEXT_R, RS_TEXT_G, RS_TEXT_B)

        if row.roleIcon then row.roleIcon:Hide() end

        if GetSetting("bgeShowPower", true) then
            row.power:SetMinMaxValues(0, 100)
            row.power:SetValue(65 - (i * 4 % 40))
            row.power:SetStatusBarColor(0.0, 0.55, 1.0, 0.9)
            row.power:Show()
        else
            row.power:Hide()
        end

        UpdateNameClipToHPFill(row)
        row:SetAlpha(1)
    end

    for i = want + 1, self.maxPlates do
        local row = self.rows[i]
        if row then
            row._preview = false
            self:ReleaseRow(row)
        end
    end
end

function BGE:ApplyRowLayout(row)
    -- Do NOT touch size/points in combat lockdown (SecureActionButtonTemplate).
    if InLockdown() then return end

    local w = GetSetting("bgeRowWidth", 240)
    local h = GetSetting("bgeRowHeight", 18)
    if type(h) ~= "number" or h < 15 then h = 15 end
    local showPower = GetSetting("bgeShowPower", true)

    row:SetSize(w, h)

    local iconTex = row.achievIconTex
    local achText = row.achievText
    local achTint = row.achievTint
    if not iconTex then
        iconTex, achText, achTint = GetIconTextureForEnemyName(row.fullName, row.name)
        row.achievIconTex, row.achievText, row.achievTint = iconTex, achText, achTint
    end

    local leftInset  = 2
    local rightInset = 4
    local border = 1

    local innerH = h - (border * 2)
    if innerH < 1 then innerH = 1 end

    -- Bottom strip for power, top strip for HP (class colour bar)
    local powerH = 0
    if showPower then
        powerH = math.max(2, math.floor(innerH * 0.15))
    end
    local gap = (showPower and 1 or 0) -- 1px separation between HP and power
    local hpH = innerH - powerH - gap
    if hpH < 1 then hpH = 1 end

    -- HP bar = top region only
    row.hp:ClearAllPoints()
    row.hp:SetPoint("TOPLEFT", row, "TOPLEFT", border, -border)
    row.hp:SetPoint("TOPRIGHT", row, "TOPRIGHT", -border, -border)
    row.hp:SetHeight(hpH)

    -- Power bar = bottom strip, full width
    row.power:ClearAllPoints()
    if showPower then
        row.power:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", border, border)
        row.power:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -border, border)
        row.power:SetHeight(powerH)
        row.power:Show()
    else
        row.power:Hide()
    end

    -- Role icon inside the HP bar (left side). Always reserve space so name doesn't jump.
    local roleSize = math.floor(math.max(10, math.min(h, 16)))
    roleSize = math.max(10, math.min(roleSize, 96))
    row.roleIcon:ClearAllPoints()
    row.roleIcon:SetSize(roleSize, roleSize)
    row.roleIcon:SetPoint("TOPLEFT", row.hp, "TOPLEFT", leftInset, 0)

    -- Achievements icon sizing (small + tight spacing)
    local iconSize = 8
    local iconPad  = 1
    local namePad  = 2 -- reduce space between roleIcon and achiev icon (was +4)
    local iconOffset = (iconTex and (iconSize + iconPad) or 0)

    -- Text belongs to the HP (class colour) bar, not the combined row
    row.nameText:ClearAllPoints()
    row.nameText:SetPoint("TOPLEFT", row.hp, "TOPLEFT", leftInset + roleSize + namePad + iconOffset, -1)
    if row.nameText.SetDrawLayer then row.nameText:SetDrawLayer("OVERLAY", 7) end
    if row.nameText.SetWordWrap then row.nameText:SetWordWrap(false) end
    if row.nameText.SetMaxLines then row.nameText:SetMaxLines(1) end
    row.nameText:SetJustifyH("LEFT")

    -- Clamp name width so it cannot draw past the row
    local hpW = w - (border * 2)
    local usedW = leftInset + rightInset + roleSize + namePad + iconOffset
    row.nameText:SetWidth(math.max(0, hpW - usedW))

    -- Achievements icon: inline with the name (prevents overlap with hpText)
    if iconTex then
        row.icon:ClearAllPoints()
        row.icon:SetTexture(iconTex)
        row.icon:SetSize(iconSize, iconSize)
        row.icon:SetPoint("LEFT", row.nameText, "LEFT", -(iconSize + iconPad), 1)
        if row.icon.SetDrawLayer then row.icon:SetDrawLayer("OVERLAY", 7) end
        -- Apply tint from Achievements
        if type(achTint) == "table" then
            local r = tonumber(achTint[1]) or 1
            local g = tonumber(achTint[2]) or 1
            local b = tonumber(achTint[3]) or 1
            row.icon:SetVertexColor(r, g, b)
        else
            row.icon:SetVertexColor(1, 1, 1)
        end
        row.icon:Show()

        -- Tooltip hit area matches icon
        if row.iconHit then
            row.iconHit:ClearAllPoints()
            row.iconHit:SetAllPoints(row.icon)
            row.iconHit:Show()
        end
    else
        row.icon:Hide()
        row.icon:ClearAllPoints()
        if row.iconHit then
            row.iconHit:Hide()
            row.iconHit:ClearAllPoints()
        end
    end

    -- hpText must already exist (created once in MakeRow). Only reposition here.
    if row.hpText then
        row.hpText:ClearAllPoints()
        row.hpText:SetPoint("CENTER", row, "CENTER", 0, -1)
        row.hpText:SetJustifyH("CENTER")
        row.hpText:SetWidth(math.max(0, w - (leftInset + rightInset + (border * 2))))
        if row.hpText.SetDrawLayer then row.hpText:SetDrawLayer("OVERLAY", 7) end
    end

    -- Dynamic font sizing based on HP bar height, then doubled.
    if row.hpText.GetFont and row.hpText.SetFont then
        local font, _, flags = row.hpText:GetFont()
        if font then
            -- Tune these two numbers:
            -- 0.45 = relative to HP bar height
            -- 20   = hard cap so it never gets huge
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

    local gap = GetSetting("bgeRowGap", 2)
    local h = GetSetting("bgeRowHeight", 18)
    if type(h) ~= "number" or h < 15 then h = 15 end

    local cols = GetSetting("bgeColumns", 1)
    local rowsPerCol = GetSetting("bgeRowsPerCol", 20)
    local colGap = GetSetting("bgeColGap", 6)
    if type(cols) ~= "number" or cols < 1 then cols = 1 end
    if type(rowsPerCol) ~= "number" or rowsPerCol < 1 then rowsPerCol = 1 end

    local w = GetSetting("bgeRowWidth", 240)
    if type(w) ~= "number" or w < 50 then w = 240 end

    -- Arena: fixed vertical stack for arena1..arena5
    if self._mode == "arena" then
        local slots = self.arenaMax
        for i = 1, slots do
            local row = self.rows[i]
            if row then
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, -((i - 1) * (h + gap)))
                self:ApplyRowLayout(row)
            end
        end
        -- Size container only to the arena stack
        local totalH = (slots * (h + gap)) - gap
        if totalH < h then totalH = h end
        self.frame:SetSize(w, totalH)
        return
    end

    -- Pre-anchor all secure rows to fixed slots (combat-safe).
    for i = 1, self.maxPlates do
        local row = self.rows[i]
        if row then
            local col = math.floor((i - 1) / rowsPerCol)
            local rix = (i - 1) % rowsPerCol
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", self.frame, "TOPLEFT", col * (w + colGap), -(rix * (h + gap)))
            self:ApplyRowLayout(row)
        end
    end

    -- Size container once (also protected in combat if it contains secure children).
    local usedCols = math.min(cols, math.max(1, math.ceil(self.maxPlates / rowsPerCol)))
    local usedRows = rowsPerCol
    local totalW = (usedCols * w) + ((usedCols - 1) * colGap)
    local totalH = (usedRows * (h + gap)) - gap
    if totalH < h then totalH = h end
    self.frame:SetSize(totalW, totalH)
end

function BGE:UpdateRowVisibilities()
    if not self.rows then return end

    if self._mode == "arena" then
        for i = 1, self.maxPlates do
            local row = self.rows[i]
            if row then
                if i <= self.arenaMax then
                    local unit = ArenaUnitFromIndex(i)
                    local active = row._preview or (UnitExists(unit) and not UnitIsFriend("player", unit))
                    row:SetAlpha(active and 1 or 0)
                else
                    row:SetAlpha(0)
                end
            end
        end
        return
    end

    -- Fallback latch: after /reload mid-match, match-state APIs can be late.
    -- IMPORTANT: Do NOT use GetBattlefieldInstanceRunTime here; it can be >0 during the BG prep countdown,
    -- which incorrectly marks everyone as out-of-range at the start.
    if not self._oorEnabled then
        -- Only latch when the match is Engaged (not Waiting/StartUp).
        if self.IsMatchStarted and self:IsMatchStarted() then
            self._oorEnabled = true
        end
    end

    local oorEnabled = self._oorEnabled and true or false

    local playerDead = false
    if oorEnabled and _G.UnitIsDeadOrGhost then
        local ok, dead = pcall(_G.UnitIsDeadOrGhost, "player")
        playerDead = ok and dead or false
    end

    for i = 1, self.maxPlates do
        local row = self.rows[i]
        if row then
            if row._preview then
                row._outOfRange = false
                ApplyClassAlpha(row, CLASS_ALPHA_ACTIVE)
                row:SetAlpha(ROW_ALPHA_ACTIVE)
            elseif row._seenIdentity then
                -- If this unit is dead, dim it (dead should not look fully active).
                local isDead = false
                if row.unit and UnitExists(row.unit) and UnitIsDeadOrGhost then
                    local okD, d = pcall(UnitIsDeadOrGhost, row.unit)
                    isDead = okD and d or false
                end
                if isDead then
                    row._outOfRange = false
                    ApplyClassAlpha(row, 0.50)
                    row:SetAlpha(0.50)

                -- 1) Prep phase (before gates open): keep everything solid/clear.
                elseif not oorEnabled then
                    row._outOfRange = false
                    ApplyClassAlpha(row, CLASS_ALPHA_ACTIVE)
                    row:SetAlpha(ROW_ALPHA_ACTIVE)

                -- 3) If I'm dead/ghosted: treat everything as out of range.
                elseif playerDead then
                    row._outOfRange = true
                    ApplyClassAlpha(row, CLASS_ALPHA_OOR)
                    row:SetAlpha(ROW_ALPHA_OOR)

                -- 2) Match started (gates open): out-of-range is based on nameplate presence.
                else
                    local activeUnit = self:ResolveEnemyPrimaryUnitID(row)
                    if activeUnit and UnitExists(activeUnit) and not UnitIsFriend("player", activeUnit) then
                        row._outOfRange = false
                        ApplyClassAlpha(row, CLASS_ALPHA_ACTIVE)
                        row:SetAlpha(ROW_ALPHA_ACTIVE)
                    else
                        row._outOfRange = true
                        ApplyClassAlpha(row, CLASS_ALPHA_OOR)
                        row:SetAlpha(ROW_ALPHA_OOR)
                    end
                end
            else
                row:SetAlpha(0)
            end
        end
    end
end

function BGE:GetRowForUnit(unit)
    local idx
    if self._mode == "arena" then
        idx = ArenaIndex(unit)
    else
        idx = NameplateIndex(unit)
    end
    if not idx or idx > self.maxPlates then return nil end
    return self.rows[idx]
end
function BGE:ReleaseRow(row)
    if not row then return end

    if row.unit and self.rowByUnit and self.rowByUnit[row.unit] == row then
        self.rowByUnit[row.unit] = nil
    end
    if row.guid and self.rowByGuid and self.rowByGuid[row.guid] == row then
        self.rowByGuid[row.guid] = nil
    end

    row.unit = nil
    row.unitID = nil
    row._unitIDKind = nil
    if row.UnitIDs then
        wipe(row.UnitIDs)
    end
    row.guid = nil
    row.name = nil
    row.fullName = nil
    row.achievIconTex = nil
    row.achievText = nil
    row.achievTint = nil
    row.classFile = nil
    row.role = nil
    row.specID = nil
    row._seenIdentity = nil
    row._outOfRange = false
    pcall(row.hpText.SetText, row.hpText, "")
    row.nameText:SetText("")
    if row.roleIcon then row.roleIcon:Hide() end
    row.hp:SetMinMaxValues(0, 1)
    row.hp:SetValue(0)
    row.power:SetMinMaxValues(0, 1)
    row.power:SetValue(0)
    row.power:Hide()
    row.bg:SetColorTexture(0, 0, 0, 0.35)
    row:SetAlpha(0)
end

function BGE:UpdateIdentity(row, unit)
    if not UnitExists(unit) then return end
    if UnitIsFriend("player", unit) and not row.unit then return end

    local oldGuid = row.guid
    local guid = SafeUnitGUID(unit)
    local full, base = GetNameplateDisplayNames(unit)
    local name = base or full
    if not name then
        name = SafeUnitName(unit)
    end
    local _, classFile = SafeUnitClass(unit)

    if oldGuid and self.rowByGuid and self.rowByGuid[oldGuid] == row and oldGuid ~= guid then
        self.rowByGuid[oldGuid] = nil
    end

    row.guid = guid
    row.fullName = full or row.fullName
    row.name = name or row.name
    row.role = nil
    row.specID = nil
    if row.roleIcon then row.roleIcon:Hide() end

    if row.guid and self.rowByGuid then
        self.rowByGuid[row.guid] = row
    end

    if row.name then
        row.nameText:SetText(row.name)
        row._seenIdentity = true
    end

    local classAlpha = (row and row._outOfRange) and CLASS_ALPHA_OOR or CLASS_ALPHA_ACTIVE
    if classFile then
        row.classFile = classFile
        local r, g, b = GetClassRGB(classFile)
        row.bg:SetColorTexture(0, 0, 0, 0.35)
        row.hp:SetStatusBarColor(r, g, b, classAlpha)
        row._seenIdentity = true
    end

    UpdateNameClipToHPFill(row)

    local hadAchTex = row.achievIconTex
    if row.achievIconTex == nil then
        row.achievIconTex, row.achievText, row.achievTint = GetIconTextureForEnemyName(row.fullName, row.name)
    end
    local iconTex = row.achievIconTex
    if iconTex then
        row.icon:SetTexture(iconTex)
        row.icon:Show()
    else
        row.icon:Hide()
    end

    if (not hadAchTex) and iconTex then
        if InLockdown() then
            self._anchorsDirty = true
        else
            self:ApplyRowLayout(row)
        end
    end
end

function BGE:StartLiveBarPoller()
    if self._liveBarPoller then return end
    if not (C_Timer and C_Timer.NewTicker) then return end

    self._liveBarPoller = C_Timer.NewTicker(0.5, function()
        local b = _G.RSTATS_BGE
        if not b then return end
        if b._mode == "arena" then return end
        if not GetSetting("bgeEnabled", true) then return end
        if not IsInPVPInstance() then return end
        b:PollLiveBars()
    end)
end

function BGE:StopLiveBarPoller()
    if self._liveBarPoller then
        self._liveBarPoller:Cancel()
        self._liveBarPoller = nil
    end
end

function BGE:StartTargetScanner()
    if self._targetScanner then return end
    if not (C_Timer and C_Timer.NewTicker) then return end

    self._targetScanner = C_Timer.NewTicker(0.5, function()
        if not _G.RSTATS_BGE then return end
        if not GetSetting("bgeEnabled", true) then return end
        if _G.RSTATS_BGE._mode == "arena" then return end
        if not IsInPVPInstance() then return end
        _G.RSTATS_BGE:ScanTargets()
        _G.RSTATS_BGE:ScanNameplateTargets()
    end)
end

function BGE:StopTargetScanner()
    if self._targetScanner then
        self._targetScanner:Cancel()
        self._targetScanner = nil
    end
end

function BGE:PollLiveBars()
    if self._mode == "arena" then return end
    if not GetSetting("bgeEnabled", true) then return end
    if not IsInPVPInstance() then return end
    if not self.rows then return end

    -- Prep phase: be aggressive and run the full opener binder so visible enemy
    -- nameplates get attached before gates open, without requiring clicks.
    -- After the match starts, switch back to the lighter scan so we don't churn
    -- live bindings every tick.
    do
        local now = GetTime()
        local last = self._lastLiveBindScanAt or 0
        local started = self.IsMatchStarted and self:IsMatchStarted()
        if (not started) and (now - last) >= 0.25 then
            self._lastLiveBindScanAt = now
            for j = 1, (self.maxPlates or 40) do
                local u = "nameplate" .. tostring(j)
                if UnitExists(u) and not UnitIsFriend("player", u) then
                    self:HandlePlateAdded(u)
                end
            end
        end
    end

    for i = 1, self.maxPlates do
        local row = self.rows[i]
        if row then
            local unit = row.unit

            if unit and UnitExists(unit) and not UnitIsFriend("player", unit) then
                -- These will fall back to reading the nameplate StatusBars when Unit* APIs are blocked.
                self:UpdateHealth(row, unit)
                self:UpdatePower(row, unit)
                if GetSetting("bgeDebug", false) and IsNameplateUnit(unit) and not FontStringHasText(row.hpText) then
                    DPrintMissing("POLLNOHP_" .. tostring(row.fullName or row.name or i),
                        "POLLNOHP row=" .. tostring(row.fullName or row.name or "nil") ..
                        " unit=" .. tostring(unit) ..
                        " resolved=" .. tostring((self.ResolveEnemyPrimaryUnitID and self:ResolveEnemyPrimaryUnitID(row)) or "nil") ..
                        " unitIDKind=" .. tostring(row._unitIDKind or "nil")
                    )
                end
            end
        end
    end
    if GetSetting("bgeDebug", false) then
        for i = 1, self.maxPlates do
            local row = self.rows[i]
            if row and row._seenIdentity and not row._preview then
                local resolved = self.ResolveEnemyPrimaryUnitID and self:ResolveEnemyPrimaryUnitID(row) or nil
                if not row.unit and not resolved then
                    DPrintMissing("ORPHANROW_" .. tostring(row.fullName or row.name or i),
                        "ORPHANROW row=" .. tostring(row.fullName or row.name or "nil") ..
                        " unit=nil resolved=nil groupTarget=" .. tostring((row.UnitIDs and row.UnitIDs.GroupTarget) or "nil") ..
                        " unitIDKind=" .. tostring(row._unitIDKind or "nil")
                    )
                end
            end
        end
    end
end

function BGE:UpdateHealth(row, unit)
    local readUnit = unit
    if self._mode ~= "arena" and row and row.unit and UnitExists(row.unit) then
        readUnit = row.unit
    end
    if not readUnit or not UnitExists(readUnit) then return end

    if UnitIsDeadOrGhost and UnitIsDeadOrGhost(readUnit) then
        pcall(row.hp.SetMinMaxValues, row.hp, 0, 1)
        pcall(row.hp.SetValue, row.hp, 0)
        pcall(row.hpText.SetText, row.hpText, "DEAD")
        return
    end

    local okH, cur = pcall(UnitHealth, readUnit)
    local okM, maxv = pcall(UnitHealthMax, readUnit)
    if okH and okM then
        -- Midnight hostile values may be secret numbers.
        -- Do not compare, format, divide, or tostring them here.
        pcall(row.hp.SetMinMaxValues, row.hp, 0, maxv)
        pcall(row.hp.SetValue, row.hp, cur)
        row._lastHpCur = cur
        row._lastHpMax = maxv
    end

    local mode = GetSetting("bgeHealthTextMode", 2)
    local txt

    if mode == 3 then
        local pct
        if UnitHealthPercent then
            local curve = (CurveConstants and CurveConstants.ScaleTo100) or nil
            local okP, v = pcall(UnitHealthPercent, readUnit, true, curve)
            if okP then
                pct = v
            end
        end

        if pct ~= nil then
            local okTxt, s = pcall(string.format, "%.0f%%", pct)
            if okTxt then
                txt = s
            end
        end

        if txt == nil and self._mode ~= "arena" and IsNameplateUnit(readUnit) then
            local sb = row._hpSB
            if sb == nil then
                sb = FindPlateHealthStatusBar(readUnit)
                row._hpSB = sb or false
            elseif sb == false then
                sb = nil
            end
            if sb then
                local pctFill = SafePercentFromStatusBarFill(sb)
                if pctFill then
                    txt = pctFill .. "%"
                end
            end
        end
    else
        -- Current / CurrentTotal cannot be built safely from secret hostile values.
        -- Prefer Blizzard numeric plate text if present, otherwise percent from bar fill.
        if self._mode ~= "arena" and IsNameplateUnit(readUnit) then
            local sb = row._hpSB
            if sb == nil then
                sb = FindPlateHealthStatusBar(readUnit)
                row._hpSB = sb or false
            elseif sb == false then
                sb = nil
            end
            if sb then
                local s = SafePlateHealthNumericText(sb)
                if s then
                    txt = s
                end
            end
            if txt == nil and sb then
                local pctFill = SafePercentFromStatusBarFill(sb)
                if pctFill then
                    txt = pctFill .. "%"
                end
            end
        end
    end

    if txt then
        pcall(row.hpText.SetText, row.hpText, txt)
    end

    UpdateNameClipToHPFill(row)
end

function BGE:UpdatePower(row, unit)
    local readUnit = unit
    if self._mode ~= "arena" and row and row.unit and UnitExists(row.unit) then
        readUnit = row.unit
    end
    if not GetSetting("bgeShowPower", true) then
        row.power:Hide()
        return
    end
    if not readUnit or not UnitExists(readUnit) then
        row.power:Hide()
        return
    end

    local okC, cur = pcall(UnitPower, readUnit)
    local okM, maxv = pcall(UnitPowerMax, readUnit)
    if not okC or not okM then
        row.power:Hide()
        return
    end

    local r, g, b = 0.0, 0.55, 1.0
    local okT, powerType = pcall(UnitPowerType, readUnit)
    if okT and PowerBarColor and PowerBarColor[powerType] then
        local c = PowerBarColor[powerType]
        r, g, b = c.r or r, c.g or g, c.b or b
    end

    pcall(row.power.SetMinMaxValues, row.power, 0, maxv)
    pcall(row.power.SetValue, row.power, cur)
    pcall(row.power.SetStatusBarColor, row.power, r, g, b, 0.9)
    row.power:Show()
end

function BGE:GetRowForExternalUnit(unitID)
    if not unitID or not UnitExists(unitID) then return nil end
    if UnitIsFriend("player", unitID) then return nil end

    for _, row in ipairs(self.rows or {}) do
        if row and not row._preview and row.unit then
            local okSame, same = pcall(UnitIsUnit, unitID, row.unit)
            if okSame and same then
                return row
            end
        end
    end

    local guid = SafeUnitGUID(unitID)
    if guid and self.rowByGuid then
        local okRow, hit = pcall(function() return self.rowByGuid[guid] end)
        if okRow and hit then return hit end
    end

    return nil
end


function BGE:AcquireLiveRow(unit)
    if not unit or not UnitExists(unit) then return nil end

    local row = self.rowByUnit and self.rowByUnit[unit] or nil
    if row then return row end

    local guid = SafeUnitGUID(unit)
    if guid and self.rowByGuid then
        local okRow, hit = pcall(function() return self.rowByGuid[guid] end)
        if okRow and hit then return hit end
    end

    for i = 1, (self.maxPlates or 40) do
        local r = self.rows and self.rows[i] or nil
        if r and not r._preview and not r.unit and not r._seenIdentity then
            return r
        end
    end

    for i = 1, (self.maxPlates or 40) do
        local r = self.rows and self.rows[i] or nil
        if r and not r._preview and not r.unit then
            return r
        end
    end

    return nil
end

local function EnemyUnitPriorityValue(key)
    if key == "Nameplate" then return 1 end
    if key == "Target" then return 2 end
    if key == "Focus" then return 3 end
    if key == "SoftEnemy" then return 4 end
    if key == "Mouseover" then return 5 end
    if key == "GroupTarget" then return 6 end
    if key == "NameplateTarget" then return 7 end
    return 99
end

function BGE:ResolveEnemyPrimaryUnitID(row)
    if not row or not row.UnitIDs then return nil end

    local bestKey, bestUnit, bestRank = nil, nil, 999

    for key, unitID in pairs(row.UnitIDs) do
        if type(unitID) == "string" and unitID ~= "" and UnitExists(unitID) and not UnitIsFriend("player", unitID) then
            local okMatch = true

            -- For nameplates: use the existing sturdy matcher (GUID first, then display name)
            if UnitStillMatchesRow and IsNameplateUnit and IsNameplateUnit(unitID) then
                okMatch = UnitStillMatchesRow(self, row, unitID)

            -- For non-nameplate sources: validate GUID when we have one
            elseif row.guid and SafeUnitGUID then
                local g = SafeUnitGUID(unitID)
                if g and g ~= row.guid then
                    okMatch = false
                end
            end

            if not okMatch then
                row.UnitIDs[key] = nil
            else
                local rank = EnemyUnitPriorityValue(key)
                if rank < bestRank then
                    bestRank = rank
                    bestKey = key
                    bestUnit = unitID
                end
            end
        else
            -- Purge dead or friendly tokens
            row.UnitIDs[key] = nil
        end
    end

    row.unitID = bestUnit
    row._unitIDKind = bestKey
    return bestUnit
end

function BGE:UpdateEnemyUnitID(row, key, value)
    if not row or not key then return end
    row.UnitIDs = row.UnitIDs or {}

    -- Track which row currently "owns" a unit token like target/focus/raidNtarget
    self._unitTokenOwner = self._unitTokenOwner or {}

    -- Remove old ownership mapping for this key on this row
    local old = row.UnitIDs[key]
    if old and self._unitTokenOwner[old] and self._unitTokenOwner[old].row == row and self._unitTokenOwner[old].key == key then
        self._unitTokenOwner[old] = nil
    end

    -- Clear
    if not value or value == "" or (not UnitExists(value)) or UnitIsFriend("player", value) then
        row.UnitIDs[key] = nil
        self:ResolveEnemyPrimaryUnitID(row)
        return
    end

    -- Reject obvious token drift when GUID is available
    if row.guid and SafeUnitGUID then
        local g = SafeUnitGUID(value)
        if g and g ~= row.guid then
            return
        end
    end

    -- If another row already owns this token, revoke it there immediately
    local owner = self._unitTokenOwner[value]
    if owner and owner.row and owner.row ~= row then
        if owner.row.UnitIDs then
            owner.row.UnitIDs[owner.key] = nil
        end
        if owner.row._altUnit == value then
            owner.row._altUnit = nil
        end
        if owner.row.unitID == value then
            owner.row.unitID = nil
            owner.row._unitIDKind = nil
        end
        if self.ResolveEnemyPrimaryUnitID then
            self:ResolveEnemyPrimaryUnitID(owner.row)
        end
    end

    self._unitTokenOwner[value] = { row = row, key = key }
    row.UnitIDs[key] = value

    self:ResolveEnemyPrimaryUnitID(row)
end

function BGE:ScanNameplateTargets()
    if self._mode == "arena" then return end
    if not GetSetting("bgeEnabled", true) then return end
    if not IsInPVPInstance() then return end

    for i = 1, (self.maxPlates or 40) do
        local sourceUnit = "nameplate" .. tostring(i)
        local targetUnit = sourceUnit .. "target"

        if UnitExists(targetUnit) and not UnitIsFriend("player", targetUnit) then
            local row = self:GetRowForExternalUnit(targetUnit)
            if row then
                self:UpdateEnemyUnitID(row, "NameplateTarget", targetUnit)
            end
        end
    end
end

function BGE:ScanTargets()
    if self._mode == "arena" then return end
    if not GetSetting("bgeEnabled", true) then return end
    if not IsInPVPInstance() then return end
    if not self.rowByGuid then return end -- not seeded yet

    local anyHit = false
    local units = self._scanUnits
    if not units then
        units = {}
        self._scanUnits = units
    end
    wipe(units)

    local n = 0

    -- Primary personal sources
    n = n + 1; units[n] = "target"
    n = n + 1; units[n] = "targettarget"
    n = n + 1; units[n] = "focus"
    n = n + 1; units[n] = "focustarget"
    n = n + 1; units[n] = "mouseover"
    n = n + 1; units[n] = "mouseovertarget"
    n = n + 1; units[n] = "pettarget"
    if UnitExists("softenemy") or (UnitGUID and pcall(UnitGUID, "softenemy")) then
        n = n + 1; units[n] = "softenemy"
        n = n + 1; units[n] = "softenemytarget"
    end

    -- In long fights, this function can become steady overhead.
    -- Throttle in combat to reduce CPU while keeping updates flowing.
    do
        local now = GetTime()
        if UnitAffectingCombat and UnitAffectingCombat("player") then
            local last = self._lastScanTargetsAt or 0
            if (now - last) < 1.0 then
                return
            end
        end
        self._lastScanTargetsAt = now
    end

    -- Ally targets (raidNtarget / partyNtarget)
    -- Staggered: scanning every raid member every 0.5s is unnecessary and causes hitching in big fights.
    -- We cycle through the group over multiple ticks instead.
    if IsInRaid() then
        local m = GetNumGroupMembers() or 0
        if m > 0 then
            local perTick = (m <= 15) and 15 or 10
            local startIdx = self._scanGroupCursor or 1
            if startIdx > m then startIdx = 1 end
            for k = 0, perTick - 1 do
                local idx = startIdx + k
                if idx > m then idx = idx - m end
                n = n + 1
                units[n] = "raid" .. idx .. "target"
                n = n + 1
                units[n] = "raid" .. idx .. "pettarget"
            end
            self._scanGroupCursor = startIdx + perTick
        end
    elseif IsInGroup() then
        local m = (GetNumGroupMembers() or 0) - 1
        if m > 0 then
            local perTick = (m <= 15) and 15 or 10
            local startIdx = self._scanGroupCursor or 1
            if startIdx > m then startIdx = 1 end
            for k = 0, perTick - 1 do
                local idx = startIdx + k
                if idx > m then idx = idx - m end
                n = n + 1
                units[n] = "party" .. idx .. "target"
                n = n + 1
                units[n] = "party" .. idx .. "pettarget"
            end
            self._scanGroupCursor = startIdx + perTick
        end
    else
        self._scanGroupCursor = 1
    end

    for i = 1, n do
        local u = units[i]
        if u and UnitExists(u) and (not UnitIsFriend("player", u)) then
            local row = self:GetRowForExternalUnit(u)
            if row then
                local sourceKey = "GroupTarget"
                if u == "target" or u == "targettarget" or u == "pettarget" then
                    sourceKey = "Target"
                elseif u == "focus" or u == "focustarget" then
                    sourceKey = "Focus"
                elseif u == "mouseover" or u == "mouseovertarget" then
                    sourceKey = "Mouseover"
                elseif u == "softenemy" or u == "softenemytarget" then
                    sourceKey = "SoftEnemy"
                end

                self:UpdateEnemyUnitID(row, sourceKey, u)
                anyHit = true
            end
        end
    end
    -- Critical: visibility/alpha is decided in UpdateRowVisibilities().
    -- Without this, rows can stay permanently faded even while alt units are updating.
    if anyHit then
        local now = GetTime()
        local lastV = self._lastVisFromScanAt or 0
        if (now - lastV) >= 1.5 then
            self._lastVisFromScanAt = now
            self:UpdateRowVisibilities()
        end
    end
end

function BGE:HandleUnitTargetChanged(srcUnit)
    if self._mode == "arena" then return end
    if not GetSetting("bgeEnabled", true) then return end
    if not IsInPVPInstance() then return end
    if not srcUnit or not UnitExists(srcUnit) then return end

    local targetUnit = srcUnit .. "target"
    if not UnitExists(targetUnit) then return end
    if UnitIsFriend("player", targetUnit) then return end

    local row = self:GetRowForExternalUnit(targetUnit)
    if not row then return end

    self:UpdateEnemyUnitID(row, "GroupTarget", targetUnit)
end

function BGE:HandlePlateAdded(unit)
    if self._mode == "arena" then return end
    if not IsNameplateUnit(unit) then return end
    if not UnitExists(unit) then return end

    if not GetSetting("bgeEnabled", true) then return end
    if not IsInPVPInstance() then return end
    if UnitIsFriend("player", unit) then return end

    local row = self:AcquireLiveRow(unit)
    if not row then return end

    ClearUnitCollision(self, unit, row)

    if row.unit and self.rowByUnit[row.unit] == row then
        self.rowByUnit[row.unit] = nil
    end

    row.unit = unit
    row.UnitIDs = row.UnitIDs or {}
    row.UnitIDs.Nameplate = unit
    row.unitID = unit
    row._unitIDKind = "Nameplate"
    row._preview = false
    row._outOfRange = false
    self.rowByUnit[unit] = row

    if row._barsUnit ~= unit then
        row._barsUnit = nil
        row._hpSB = nil
        row._pwrSB = nil
        row._hpSBAt = nil
        row._pwrSBAt = nil
    end

    self:UpdateIdentity(row, unit)
    self:UpdateHealth(row, unit)
    self:UpdatePower(row, unit)
    ApplyClassAlpha(row, CLASS_ALPHA_ACTIVE)

    self:UpdateRowVisibilities()
    self:SyncSelectedRowToTarget()
end

function BGE:HandlePlateRemoved(unit)
    if self._mode == "arena" then return end
    if not IsNameplateUnit(unit) then return end
    local row = self.rowByUnit and self.rowByUnit[unit] or nil
    if not row then return end

    -- Do NOT wipe. Keep last known identity/bars and just fade until it returns.
    row.unit = nil
	if row.UnitIDs then
		row.UnitIDs.Nameplate = nil
	end
	row.unitID = nil
	if self.ResolveEnemyPrimaryUnitID then
		self:ResolveEnemyPrimaryUnitID(row)
	end
    row._barsUnit = nil
    row._hpSB = nil
    row._pwrSB = nil
    self.rowByUnit[unit] = nil
    row._outOfRange = true
    -- Don't force-hide power: it may still refresh via target/focus/ally-target unit tokens.
    ApplyClassAlpha(row, CLASS_ALPHA_OOR)
    row:SetAlpha(row._seenIdentity and ROW_ALPHA_OOR or 0)
end

function BGE:HandleUnitUpdate(unit, what, force)
    if not GetSetting("bgeEnabled", true) then return end
    local mappedRow = (self._mode ~= "arena") and (self.rowByUnit and self.rowByUnit[unit]) or nil
    if self._mode ~= "arena" then
        if not IsInPVPInstance() then return end
        if not UnitExists(unit) then return end
        if UnitIsFriend("player", unit) and not mappedRow then return end
    end
    if self._mode == "arena" then
        if not IsArenaUnit(unit) then return end
    else
        if not IsNameplateUnit(unit) and unit ~= "target" and unit ~= "focus" and unit ~= "mouseover" and unit ~= "softenemy" and not unit:find("target") then
            return
        end
    end

    local row = mappedRow or self:GetRowForUnit(unit)
    if not row and self._mode ~= "arena" and not IsNameplateUnit(unit) then
        row = self:GetRowForExternalUnit(unit)
    end
    if not row then return end

    if (not row.name or not row.classFile) and not row._preview then
        self:UpdateIdentity(row, unit)
    end

    self:UpdateHealth(row, unit)
    self:UpdatePower(row, unit)
    self:UpdateRowVisibilities()
end

function BGE:RefreshVisibility()
    if not self.frame then return end

    local preview = GetSetting("bgePreview", false)
    if not IsInPVPInstance() and not preview then
        self:StopTargetScanner()
        self:StopLiveBarPoller()
        self:ClearPreviewRows()
        for _, row in ipairs(self.rows) do
            self:ReleaseRow(row)
        end
        wipe(self.rowByGuid)
        wipe(self.rowByUnit)
        self._matchStarted = false
        self._oorEnabled = false
        self.frame:SetAlpha(0)
        if not InLockdown() then
            self.frame:Hide()
        end
        return
    end

    if not IsInPVPInstance() then
        local db = GetPlayerDB()
        self._profilePrefix = ResolvePreviewProfilePrefix(db)
    end

    if not self.frame:IsShown() then
        if InLockdown() then
            self._showDirty = true
        else
            self.frame:Show()
        end
    end
    self.frame:SetAlpha(1)

    if IsInPVPInstance() and self._mode ~= "arena" then
        self:StartTargetScanner()
        self:StartLiveBarPoller()
    else
        self:StopTargetScanner()
        self:StopLiveBarPoller()
    end

    local want = 10
    local isRatedBG = false
    local isRatedSoloRBG = false
    local isSoloRBG = false

    if (not preview) and IsInPVPInstance() and self._mode ~= "arena" then
        if C_PvP and C_PvP.IsRatedSoloRBG then
            local okS, s = pcall(C_PvP.IsRatedSoloRBG)
            if okS and s then isRatedSoloRBG = true end
        end
        if C_PvP and C_PvP.IsSoloRBG then
            local okSR, sr = pcall(C_PvP.IsSoloRBG)
            if okSR and sr then isSoloRBG = true end
        end
        if isRatedSoloRBG then isSoloRBG = true end

        if (not isRatedSoloRBG) and C_PvP and C_PvP.IsRatedBattleground then
            local okR, r = pcall(C_PvP.IsRatedBattleground)
            if okR and r then isRatedBG = true end
        elseif (not isRatedSoloRBG) and _G.IsRatedBattleground then
            local okR, r = pcall(_G.IsRatedBattleground)
            if okR and r then isRatedBG = true end
        end
    end

    if preview then
        want = GetSetting("bgePreviewCount", 8)
    elseif self._mode == "arena" then
        want = self.arenaMax or 5
    else
        if isSoloRBG then
            want = 8
        elseif isRatedBG then
            want = 10
        else
            local _, instType, _, _, maxPlayers, _, _, instMapID = GetInstanceInfo()
            if instType == "pvp" then
                if type(maxPlayers) == "number" and maxPlayers > 15 then
                    want = math.min(maxPlayers, self.maxPlates or 40)
                elseif maxPlayers == 15 then
                    want = 15
                else
                    want = 10
                end
                if maxPlayers == 10 and (instMapID == 461 or instMapID == 482 or instMapID == 935) then
                    want = 15
                end
            end
        end
    end

    if (not preview) and IsInPVPInstance() and self._mode ~= "arena" then
        if isSoloRBG and want == 8 then
            self._profilePrefix = "bgeRated"
        elseif isRatedBG then
            self._profilePrefix = "bge10"
        elseif want and want > 15 then
            self._profilePrefix = "bgeLarge"
        elseif want == 15 then
            self._profilePrefix = "bge15"
        else
            self._profilePrefix = "bge10"
        end
    end

    if want > (self.maxPlates or 40) then want = (self.maxPlates or 40) end
    self:EnsureSecureRows(want)

    self:UpdateFrameTeamTint()
    self:EnsurePreviewRows()

    if IsInPVPInstance() and self._mode ~= "arena" then
        for i = 1, self.maxPlates do
            local u = "nameplate" .. i
            if UnitExists(u) then
                self:HandlePlateAdded(u)
            end
        end
    end

    self:UpdateRowVisibilities()
end

function BGE:HandleArenaUnit(unit)
    if self._mode ~= "arena" then return end
    if not IsArenaUnit(unit) then return end

    if not GetSetting("bgeEnabled", true) then return end
    if not IsInPVPInstance() then return end

    local idx = ArenaIndex(unit)
    if not idx or idx > self.arenaMax then return end
    local row = self.rows[idx]
    if not row then return end

    if UnitExists(unit) and UnitIsPlayer(unit) and UnitIsEnemy("player", unit) then
        row.unit = unit
        row._preview = false
        self:UpdateIdentity(row, unit)
        self:UpdateHealth(row, unit)
        self:UpdatePower(row, unit)
        row:SetAlpha(1)
    else
        self:ReleaseRow(row)
    end
    self:UpdateRowVisibilities()
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
    if (showAch ~= self._lastShowAchievIcon) or (apiPresent ~= self._lastAchievAPIPresent) then
        self._lastShowAchievIcon = showAch
        self._lastAchievAPIPresent = apiPresent
        self.achievCache = nil
        for i = 1, self.maxPlates do
            local row = self.rows and self.rows[i] or nil
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

    self:ApplyMode()
    self:RefreshVisibility()
    self:UpdateFrameTeamTint()
    self:ApplyAnchors()
    self:UpdateRowVisibilities()
end

CreateMainFrame = function()
    local f = CreateFrame("Frame", "RatedStats_BGE_Frame", UIParent)
    BGE.frame = f

    local p  = GetSetting("bgePoint", "LEFT")
    local rp = GetSetting("bgeRelPoint", "LEFT")
    local x  = GetSetting("bgeX", 30)
    local y  = GetSetting("bgeY", 0)

    f:SetPoint(p, UIParent, rp, x, y)
    f:SetFrameStrata("HIGH")
    f:SetSize(GetSetting("bgeRowWidth", 240), 20)

    -- Visible only in preview (so you can see the container)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints(true)
    f.bg:SetColorTexture(0, 0, 0, 0) -- set in RefreshVisibility

    -- Hover-only anchor TAB (chat-style), with right-click menu.
    -- This inherits the same textures used for chat window tabs, but we provide our own scripts.
    f.anchorTab = CreateFrame("Button", nil, f, "ChatTabArtTemplate")
    f.anchorTab:SetPoint("BOTTOMLEFT", f, "TOPLEFT", -2, 2)
    f.anchorTab:SetFrameLevel((f:GetFrameLevel() or 0) + 10)
    f.anchorTab:SetAlpha(0.9)
    f.anchorTab:Hide()
    f.anchorTab:RegisterForClicks("RightButtonUp")

    -- Tab label
    f.anchorTab.Text = f.anchorTab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.anchorTab.Text:SetPoint("CENTER", f.anchorTab, "CENTER", 0, -5)
    f.anchorTab.Text:SetText("Rated Stats - BGE")

    -- Size the tab to fit the text (min width keeps it looking like a real tab)
    local w = (f.anchorTab.Text:GetStringWidth() or 60) + 40
    if w < 120 then w = 120 end
    f.anchorTab:SetWidth(w)

    -- Keep "active" art visible so it reads like a real attached tab.
    if f.anchorTab.ActiveLeft then f.anchorTab.ActiveLeft:Show() end
    if f.anchorTab.ActiveMiddle then f.anchorTab.ActiveMiddle:Show() end
    if f.anchorTab.ActiveRight then f.anchorTab.ActiveRight:Show() end

    -- ChatTabArtTemplate already wires mouse handlers; OnClick isn't reliable here.
    -- Hook OnMouseUp so right-click always opens the menu.
    f.anchorTab:HookScript("OnMouseUp", function(tab, button)
        if button ~= "RightButton" then return end
        local bge = _G.RSTATS_BGE
        if bge and bge.ShowAnchorMenu then
            bge:ShowAnchorMenu(tab)
        end
    end)
    f.anchorTab:SetScript("OnEnter", function()
        local bge = _G.RSTATS_BGE
        if bge and bge.AnchorHoverBegin then
            bge:AnchorHoverBegin()
        end
    end)
    f.anchorTab:SetScript("OnLeave", function()
        local bge = _G.RSTATS_BGE
        if bge and bge.AnchorHoverEnd then
            bge:AnchorHoverEnd()
        end
    end)

    -- If the container itself is mouse-enabled (unlocked), also show the anchor on hover.
    f:SetScript("OnEnter", function()
        local bge = _G.RSTATS_BGE
        if bge and bge.AnchorHoverBegin then
            bge:AnchorHoverBegin()
        end
    end)
    f:SetScript("OnLeave", function()
        local bge = _G.RSTATS_BGE
        if bge and bge.AnchorHoverEnd then
            bge:AnchorHoverEnd()
        end
    end)

    -- Do not create secure rows until we actually need them (PvP or Preview).
    -- Also keep the container hidden out of PvP to avoid a "ghost frame" on login.
    f:SetAlpha(0)
    f:Hide()

    -- IMPORTANT: Do NOT create an always-on target scan ticker here.
    -- We already start/stop scanning via StartTargetScanner() in RefreshVisibility().

    BGE:ApplySettings()
end

local evt = CreateFrame("Frame")
evt:RegisterEvent("PLAYER_LOGIN")
evt:RegisterEvent("PLAYER_ENTERING_WORLD")
evt:RegisterEvent("ZONE_CHANGED_NEW_AREA")

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
pcall(function() evt:RegisterEvent("UNIT_HEALTH_FREQUENT") end)
pcall(function() evt:RegisterEvent("UNIT_POWER_FREQUENT") end)
pcall(function() evt:RegisterEvent("UNIT_TARGET") end)
evt:RegisterEvent("PLAYER_REGEN_ENABLED")
evt:RegisterEvent("PLAYER_DEAD")
evt:RegisterEvent("PLAYER_ALIVE")
evt:RegisterEvent("PLAYER_UNGHOST")

evt:RegisterEvent("ARENA_OPPONENT_UPDATE")
evt:RegisterEvent("PVP_MATCH_ACTIVE")
evt:RegisterEvent("PVP_MATCH_COMPLETE")

evt:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" then
        -- Only bootstrap BGE outside PvP if preview is enabled.
        -- This keeps BGE truly "BG-only" and avoids any chance of taint bleed in PvE.
        local preview = GetSetting("bgePreview", false)
        if not preview and not IsInPVPInstance() then
            return
        end
        CreateMainFrame()
        BGE:ApplySettings()
        return
    end

    -- Hard stop: outside PvP, ignore all events unless preview is enabled.
    -- We still allow zone transitions so settings/visibility can remain correct.
    local preview = GetSetting("bgePreview", false)
    if not preview and not IsInPVPInstance() then
        if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
            BGE:UpdateMatchState()
            BGE:ApplySettings()
        end
        return
    end

    -- Instant pulls for non-nameplate unit tokens (cheap, event-driven)
    if event == "PLAYER_TARGET_CHANGED" then
        BGE:HandleUnitUpdate("target", "NAME", true)
        BGE:HandleUnitUpdate("target", "HP", true)
        BGE:HandleUnitUpdate("target", "PWR", true)
        BGE:SyncSelectedRowToTarget()
        return
    end

    if event == "PLAYER_FOCUS_CHANGED" then
        BGE:HandleUnitUpdate("focus", "NAME", true)
        BGE:HandleUnitUpdate("focus", "HP", true)
        BGE:HandleUnitUpdate("focus", "PWR", true)
        return
    end

    if event == "UPDATE_MOUSEOVER_UNIT" then
        BGE:HandleUnitUpdate("mouseover", "NAME", true)
        BGE:HandleUnitUpdate("mouseover", "HP", true)
        BGE:HandleUnitUpdate("mouseover", "PWR", true)
        return
    end

    if event == "PLAYER_SOFT_ENEMY_CHANGED" then
        BGE:HandleUnitUpdate("softenemy", "NAME", true)
        BGE:HandleUnitUpdate("softenemy", "HP", true)
        BGE:HandleUnitUpdate("softenemy", "PWR", true)
        return
    end

    if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        -- IMPORTANT: entering/leaving BGs needs anchors/layout as well as visibility.
        BGE:UpdateMatchState()
        BGE:ApplySettings()
        return
    end

    if event == "PVP_MATCH_ACTIVE" or event == "PVP_MATCH_COMPLETE" then
        BGE:UpdateMatchState()
        BGE:UpdateRowVisibilities()
        return
    end

    if event == "PLAYER_DEAD" or event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        -- If the player dies, we intentionally treat all rows as out-of-range.
        -- When they release/resurrect, restore normal out-of-range behaviour.
        BGE:UpdateRowVisibilities()
        return
    end

    if event == "PLAYER_REGEN_ENABLED" then
        if _G.RSTATS_BGE and _G.RSTATS_BGE._showDirty then
            _G.RSTATS_BGE._showDirty = false
            _G.RSTATS_BGE.frame:Show()
            _G.RSTATS_BGE:RefreshVisibility()
        end
        if _G.RSTATS_BGE and _G.RSTATS_BGE._rowsDirty then
            _G.RSTATS_BGE._rowsDirty = false
            _G.RSTATS_BGE:RefreshVisibility()
        end
        -- If we skipped anchoring due to lockdown, apply it as soon as combat ends.
        if _G.RSTATS_BGE and _G.RSTATS_BGE._anchorsDirty then
            _G.RSTATS_BGE:ApplyAnchors()
            _G.RSTATS_BGE:UpdateRowVisibilities()
        end
        -- If we skipped a mode/unit-token swap due to lockdown, apply it now.
        if _G.RSTATS_BGE and _G.RSTATS_BGE._modeDirty then
            _G.RSTATS_BGE:ApplyMode()
            _G.RSTATS_BGE:ApplyAnchors()
            _G.RSTATS_BGE:UpdateRowVisibilities()
        end
        return
    end

    if event == "ARENA_OPPONENT_UPDATE" then
        BGE:ApplyMode()
        BGE:HandleArenaUnit(arg1)
        return
    end

    -- Don't drop events just because alpha is 0; handlers already gate on settings + PvP.
    if not BGE.frame then
        return
    end

    if event == "NAME_PLATE_UNIT_ADDED" then
        BGE:HandlePlateAdded(arg1)
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

    if event == "UNIT_POWER_UPDATE" or event == "UNIT_MAXPOWER" or event == "UNIT_DISPLAYPOWER" then
        BGE:HandleUnitUpdate(arg1, "PWR")
        return
    end

    if event == "UNIT_TARGET" then
        BGE:HandleUnitTargetChanged(arg1)
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
        if not db then return end
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
        if not db then return end
        db.settings.bgeDebug = not db.settings.bgeDebug
        print("Rated Stats - Battleground Enemies: Debug " .. (db.settings.bgeDebug and "ON" or "OFF"))
        return
    end
    print("Rated Stats - Battleground Enemies: /rstbge [preview|lock|debug]")
end