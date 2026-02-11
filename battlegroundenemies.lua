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

-- Scoreboard seed state (BG start)
BGE._seededThisBG = false
BGE._oorEnabled = false -- latch: enable out-of-range dimming only after gates open
BGE.scoreClassList = {}
-- Roster seeding list of { guid, name, classToken, specID, role }
BGE.roster = {}
BGE.rowByGuid = {}
BGE.rowByUnit = {}
BGE.rowByName = {}
BGE.nameCounts = {}
BGE.rowByFullName = {}
BGE.rowByBaseName = {}
BGE.fullNameCounts = {}
BGE.baseNameCounts = {}
BGE.rowByPID = {}
BGE.pidCounts = {}
BGE.rowByPIDNoRace = {}
BGE.pidNoRaceCounts = {}
BGE.rowByPIDLoose = {}
BGE.pidLooseCounts = {}
BGE.ClassTokenToID = nil
BGE.RaceNameToID = nil
BGE.pendingUnitByGuid = {}
BGE.pendingUnitByRow = {}
-- Last seeded roster size.
BGE._seedCount = 0
BGE._guidRetryAt = {}
BGE._plateAddRetry = {}
BGE._plateAddRetryKey = {}

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

-- Scoreboard cache: baseName -> { count = n, role = "TANK"/"HEALER"/"DAMAGER" }
BGE.scoreCache = {}
BGE.scoreCacheAt = 0

-- Combat-safe: if we want to resize after combat, stash desired size.
BGE._pendingW = nil
BGE._pendingH = nil

-- Forward declare so debug helpers can call it before its definition.
local Scrub2
local GetSetting
local UpdateNameClipToHPFill
local SafeUnitGUID
local GetNameplateDisplayNames
local UnitPID
local CalculatePID
local CalculatePIDLoose
local SafeStatusBarValues
local NormalizeFactionIndex
local UnitStillMatchesRow
local ClearUnitCollision
local CreateMainFrame

-- Debug (throttled)
BGE._dbgLast = {}

local function DPrint(key, msg)
    if not GetSetting("bgeDebug", false) then return end
    local now = GetTime()
    local last = BGE._dbgLast[key] or 0
    if (now - last) < 1.0 then return end
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
function BGE:DebugSeededGuidKeys(max)
    if not GetSetting("bgeDebug", false) then return end
    local n = 0
    for k, _ in pairs(self.rowByGuid or {}) do
        n = n + 1
        if n <= 15 then
            local ks = SafeToString(k) or "<secret>"
            DPrint("SEEDKEY" .. tostring(n), "SEED guidKey[" .. tostring(n) .. "]=" .. ks)
        end
    end
    DPrint("SEEDCOUNT", "SEED rowByGuid.count=" .. tostring(n) .. " seedCount=" .. tostring(max or 0))
end

-- Debug: compare nameplate identity vs scoreboard identity for the same GUID.
-- This is designed to NOT crash even if GUID/name are secret values.
function BGE:DebugScoreVsNameplate(tag, unit, guidKey)
    if not GetSetting("bgeDebug", false) then return end

    -- nameplate side
    local okNG, npGuidRaw = pcall(UnitGUID, unit)
    local npGuidS = SafeToString(npGuidRaw)
    if okNG and npGuidRaw and not npGuidS then npGuidS = "<secret>" end

    local okNN, npNameRaw = pcall(UnitName, unit)
    local npNameS = SafeToString(npNameRaw)
    if okNN and npNameRaw and not npNameS then npNameS = "<secret>" end

    -- Never do comparisons like (x ~= nil) if x might be secret.
    -- Just stringify; if we can't stringify, treat it as secret-ish.
    local keyS = SafeToString(guidKey)
    local keyIsSecret = false
    if guidKey and not keyS then
        keyS = "<secret>"
        keyIsSecret = true
    end

    local sbGuidS, sbNameS = nil, nil
    local hitDirect = false
    local keyType = type(guidKey)
    local keySType = type(keyS)

    -- seeded side (direct lookup)
    if guidKey and self.rowByGuid then
        local okRow, row = pcall(function() return self.rowByGuid[guidKey] end)
        if okRow and row then
            hitDirect = true
            sbGuidS = SafeToString(row.guid)
            if row.guid and not sbGuidS then sbGuidS = "<secret>" end
            sbNameS = SafeToString(row.name)
            if row.name and not sbNameS then sbNameS = "<secret>" end
        end
    end

    -- nameplate display name (frame text), avoids UnitName restrictions
    local npDispS = nil
    do
        local okP, plate = pcall(function()
            if _G.C_NamePlate and _G.C_NamePlate.GetNamePlateForUnit then
                return _G.C_NamePlate.GetNamePlateForUnit(unit)
            end
            return nil
        end)
        if okP and plate and plate.UnitFrame and plate.UnitFrame.name and plate.UnitFrame.name.GetText then
            local okT, t = pcall(plate.UnitFrame.name.GetText, plate.UnitFrame.name)
            npDispS = SafeToString(t) or (t and "<secret>" or nil)
        end
    end

    local hitByName = false
    local sbName2S = nil
    if npDispS and self.rowByName then
        local okRow2, row2 = pcall(function() return self.rowByName[npDispS] end)
        if okRow2 and row2 then
            hitByName = true
            sbName2S = SafeToString(row2.name) or (row2.name and "<secret>" or nil)
        end
    end

    DPrint("CMP:" .. tag .. ":" .. unit,
        "CMP " .. tag ..
        " unit=" .. unit ..
        " nameplate.guid=" .. (npGuidS or "nil") ..
        " nameplate.name=" .. (npNameS or "nil") ..
        " scoreboard.guid=" .. (sbGuidS or "nil") ..
        " scoreboard.name=" .. (sbNameS or "nil") ..
        " nameplate.disp=" .. (npDispS or "nil") ..
        " scoreboard.nameByDisp=" .. (sbName2S or "nil") ..
        " guidKey=" .. (keyS or "nil") ..
        " keyType=" .. tostring(keyType) ..
        " keySType=" .. tostring(keySType) ..
        " hitDirect=" .. Bool01(hitDirect) ..
        " hitByDisp=" .. Bool01(hitByName) ..
        " keySecret=" .. Bool01(keyIsSecret)
    )
end

-- After we seed new scoreboard rows, some of those players may already have
-- visible nameplates (because nameplates can appear before the scoreboard fills).
-- Scan current nameplates and bind GUID matches to seeded rows.
function BGE:ScanNameplatesForGuidBindings()
    if self._mode == "arena" then return end
    if not self.rowByGuid or not self.rowByUnit then return end

    for i = 1, (self.maxPlates or 40) do
        local unit = "nameplate" .. tostring(i)
        -- UnitIsPlayer() can be unreliable on enemy nameplates (especially after /reload mid-match).
        -- Only hard-skip confirmed friendlies.
        if unit and UnitExists(unit) and not UnitIsFriend("player", unit) then
            local row = nil
            local bindBy = nil

            -- 1) Prefer GUID match if the nameplate GUID is usable.
            local guid = SafeUnitGUID(unit)
            if guid and self.rowByGuid then
                row = self.rowByGuid[guid]
                if row then bindBy = "guid" end
            end

            -- 2) Fallback: match by displayed name text on the nameplate frame.
            local disp, dispBase
            if not row then
                disp, dispBase = GetNameplateDisplayNames(unit)
                if disp and self.rowByFullName then
                    row = self.rowByFullName[disp]
                    if row then bindBy = "disp" end
                end
                if (not row) and dispBase and self.rowByBaseName and self.baseNameCounts and self.baseNameCounts[dispBase] == 1 then
                    row = self.rowByBaseName[dispBase]
                    if row then bindBy = "dispBase" end
                end
            end

            -- 3) Fallback: PID match (when GUID + disp are unavailable).
            if not row then
                local pid = UnitPIDSeedCompat(unit)
                if pid and pid > 0 and self.rowByPID then
                    row = self.rowByPID[pid]
                    if row then bindBy = "pid" end
                end
                -- Seed-compatible loose PID
                if not row and self.rowByPIDLoose then
                    local pidL = UnitPIDLooseSeedCompat(unit)
                    if pidL and pidL > 0 then
                        row = self.rowByPIDLoose[pidL]
                        if row then bindBy = "pidLoose" end
                    end
                end
            end

            -- Rebind if missing OR stale (nameplates recycle)
            local stale = false
            if row and row.unit and UnitExists(row.unit) then
                stale = not UnitStillMatchesRow(self, row, row.unit)
            end
            if row and ((row.unit == nil) or (not UnitExists(row.unit)) or stale) then
                local pidNow = UnitPID(unit)
                DPrint("BIND_" .. unit,
                    "BIND unit=" .. unit ..
                    " by=" .. tostring(bindBy or "pid") ..
                    " pid=" .. tostring(pidNow or 0) ..
                    " rowName=" .. tostring(row.name or "nil")
                )

                -- If another row already owns this unit token, clear it (nameplate recycle)
                ClearUnitCollision(self, unit, row)

                -- If the row had an old unit mapping, clear it
                if row.unit and self.rowByUnit[row.unit] == row then
                    self.rowByUnit[row.unit] = nil
                end

                row.unit = unit
                row._preview = false
                row._outOfRange = false
                self.rowByUnit[unit] = row

                -- Force bar rescan on new unit token
                row._barsUnit = nil
                row._hpSB = nil
                row._pwrSB = nil
                row._hpSBAt = nil
                row._pwrSBAt = nil

                -- Bind secure click-to-target to this live unit token.
                if not InLockdown() then
                    row:SetAttribute("unit", unit)
                else
                    self.pendingUnitByRow = self.pendingUnitByRow or {}
                    self.pendingUnitByRow[row] = unit
                end

                -- Snap bars immediately now that we have a live unit.
                self:UpdateIdentity(row, unit)
                self:UpdateHealth(row, unit)
                self:UpdatePower(row, unit)
            end
        end
    end
end

Scrub2 = function(...)
    -- IMPORTANT:
    -- scrubsecretvalues() replaces secret values with nil. That prevents errors,
    -- but it also destroys the data (names/guids/classes become nil).
    -- We do NOT want that in operational code.
    return ...
end

local function IsNameplateUnit(unit)
    return type(unit) == "string" and unit:match("^nameplate%d+$") ~= nil
end

-- additional unit tokens that can still provide live HP/PWR.
-- This does NOT give "true global BG HP"; it only works when we can resolve a unit token.
local function IsGroupTargetUnit(unit)
    if type(unit) ~= "string" then return false end
    return unit:match("^raid%d+target$") ~= nil or unit:match("^party%d+target$") ~= nil
end

local function IsAltEnemyUnit(unit)
    if type(unit) ~= "string" then return false end
    if unit == "target" or unit == "focus" or unit == "mouseover" or unit == "softenemy" then
        return true
    end
    return IsGroupTargetUnit(unit)
end

local function IsTrackedBGUnit(unit)
    return IsNameplateUnit(unit) or IsAltEnemyUnit(unit)
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

-- Resolve a scoreboard fullName ("Name-Realm") from a GUID without touching UnitName.
-- This is the most reliable bridge on 12.0+/Midnight when UnitName/UnitGUID can be restricted.
local function ScoreFullNameFromGuid(guidRaw)
    if not guidRaw then return nil end
    if not (_G.C_PvP and _G.C_PvP.GetScoreInfoByPlayerGuid) then return nil end
    local ok, info = pcall(_G.C_PvP.GetScoreInfoByPlayerGuid, guidRaw)
    if not ok or type(info) ~= "table" then return nil end
    return SafeNonEmptyString(info.name)
end

SafeUnitGUID = function(unit)
    local ok, guid = pcall(UnitGUID, unit)
    return SafeToString(guid)
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
    -- Mercenary flips the “visual” faction; scoreboard uses the match team.
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

CalculatePID = function(classID, factionIndex, honorLevel)
    -- Legacy signature kept only to avoid hard-crashing if something calls it.
    -- Prefer the expanded signature below.
    classID = tonumber(classID) or 0
    factionIndex = tonumber(factionIndex) or 0
    honorLevel = tonumber(honorLevel) or 0
    return (classID * 1000000) + (factionIndex * 100000) + honorLevel
end

CalculatePIDLoose = function(classID, factionIndex)
    -- Legacy signature kept only to avoid hard-crashing if something calls it.
    classID = tonumber(classID) or 0
    factionIndex = tonumber(factionIndex) or 0
    return (classID * 1000000) + (factionIndex * 100000)
end

local function CalculatePIDFull(raceID, classID, level, factionIndex, sex, honorLevel)
    raceID = NormalizeRaceID(raceID)
    classID = tonumber(classID) or 0
    level = tonumber(level) or 0
    factionIndex = tonumber(factionIndex) or 0
    sex = tonumber(sex) or 0
    honorLevel = tonumber(honorLevel) or 0
    -- Multipliers chosen to minimize collisions
    return (raceID * 100000000000)
        + (classID * 1000000000)
        + (level * 10000000)
        + (factionIndex * 1000000)
        + (sex * 100000)
        + honorLevel
end

local function CalculatePIDLooseFull(raceID, classID, level, factionIndex, sex)
    raceID = NormalizeRaceID(raceID)
    classID = tonumber(classID) or 0
    level = tonumber(level) or 0
    factionIndex = tonumber(factionIndex) or 0
    sex = tonumber(sex) or 0
    return (raceID * 100000000000)
        + (classID * 1000000000)
        + (level * 10000000)
        + (factionIndex * 1000000)
        + (sex * 100000)
end

function BGE:EnsurePIDMaps()
    if self.ClassTokenToID and self.RaceNameToID then return end
    self.ClassTokenToID = {}
    for i = 1, (GetNumClasses and GetNumClasses() or 0) do
        local _, token, id = GetClassInfo(i)
        if token and id then
            self.ClassTokenToID[token] = id
        end
    end
    self.RaceNameToID = {}
    if _G.C_CreatureInfo and _G.C_CreatureInfo.GetRaceInfo then
        for i = 1, 200 do
            local info = _G.C_CreatureInfo.GetRaceInfo(i)
            if info and info.raceName and info.raceID then
                self.RaceNameToID[info.raceName] = info.raceID
            end
        end
    end
end

UnitPID = function(unit)
    if not UnitExists(unit) then return 0 end
    local okR, _, _, raceID = pcall(UnitRace, unit)
    local okC, _, _, classID = pcall(UnitClass, unit)
    local okL, level = pcall(UnitLevel, unit)
    local okS, sex = pcall(UnitSex, unit)
    local okH, honor = pcall(UnitHonorLevel, unit)
    if not okC or not classID then return 0 end
    return CalculatePIDFull(
        (okR and raceID) or 0,
        classID or 0,
        (okL and level) or 0,
        GetUnitTrueFactionIndex(unit),
        (okS and sex) or 0,
        (okH and honor) or 0
    )
end

-- Seed-compatible PID:
-- Scoreboard seed does NOT provide reliable level/sex, so seeded rows effectively use level=0 sex=0.
-- This must be used for nameplate -> row matching, otherwise PID will never hit.
UnitPIDSeedCompat = function(unit)
    if not UnitExists(unit) then return 0 end
    local okR, _, _, raceID = pcall(UnitRace, unit)
    local okC, _, _, classID = pcall(UnitClass, unit)
    local okH, honor = pcall(UnitHonorLevel, unit)
    if not okC or not classID then return 0 end
    return CalculatePIDFull(
        (okR and raceID) or 0,
        classID or 0,
        0, -- level (seed-compatible)
        GetUnitTrueFactionIndex(unit),
        0, -- sex (seed-compatible)
        (okH and honor) or 0
    )
end

-- Seed-compatible PID that ignores race (mercenary-safe fallback).
-- Mercenary mode can change the *visual* race on nameplates, so UnitRace(unit) may not match the scoreboard race.
-- This is only used as a fallback and only when it yields a unique match.
UnitPIDNoRaceSeedCompat = function(unit)
    if not UnitExists(unit) then return 0 end
    local okC, _, _, classID = pcall(UnitClass, unit)
    local okH, honor = pcall(UnitHonorLevel, unit)
    if not okC or not classID then return 0 end
    return CalculatePIDFull(
        0, -- race (ignored)
        classID or 0,
        0, -- level (seed-compatible)
        GetUnitTrueFactionIndex(unit),
        0, -- sex (seed-compatible)
        (okH and honor) or 0
    )
end

UnitPIDLooseSeedCompat = function(unit)
    if not UnitExists(unit) then return 0 end
    local okR, _, _, raceID = pcall(UnitRace, unit)
    local okC, _, _, classID = pcall(UnitClass, unit)
    if not okC or not classID then return 0 end
    return CalculatePIDLooseFull(
        (okR and raceID) or 0,
        classID or 0,
        0, -- level (seed-compatible)
        GetUnitTrueFactionIndex(unit),
        0  -- sex (seed-compatible)
    )
end

local function UnitPIDLoose(unit)
    if not UnitExists(unit) then return 0 end
    local okR, _, _, raceID = pcall(UnitRace, unit)
    local okC, _, _, classID = pcall(UnitClass, unit)
    local okL, level = pcall(UnitLevel, unit)
    local okS, sex = pcall(UnitSex, unit)
    if not okC or not classID then return 0 end
    return CalculatePIDLooseFull(
        (okR and raceID) or 0,
        classID or 0,
        (okL and level) or 0,
        GetUnitTrueFactionIndex(unit),
        (okS and sex) or 0
    )
end

GetNameplateDisplayNames = function(unit)
    if not (_G.C_NamePlate and _G.C_NamePlate.GetNamePlateForUnit) then return nil, nil end
    local okP, plate = pcall(_G.C_NamePlate.GetNamePlateForUnit, unit)
    if not okP or not plate then return nil, nil end

    local uf = plate.UnitFrame
    if not uf then return nil, nil end

    local disp = nil
    local function TryFS(fs)
        if disp then return end
        if not fs or not fs.GetText then return end
        local okT, t = pcall(fs.GetText, fs)
        local s = SafeToString(t)
        if s and s ~= "" then
            disp = s
        end
    end

    -- Common name fields across different nameplate styles
    TryFS(uf.name)
    TryFS(uf.Name)
    if uf.healthBar then
        TryFS(uf.healthBar.name)
        TryFS(uf.healthBar.unitName)
        TryFS(uf.healthBar.UnitName)
    end

    -- Last resort: scan all regions for a FontString that looks like "Name-Realm"
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

    if not disp then return nil, nil end
    local okB, base = pcall(function() return disp:match("^[^-]+") end)
    local dispBase = (okB and base) or disp
    return disp, dispBase
end

-- Nameplate units recycle. UnitExists(nameplateX) can stay true while the player behind it changes.
UnitStillMatchesRow = function(self, row, unit)
    if not unit or not UnitExists(unit) then return false end

    -- Prefer GUID if we can read it.
    if row and row.guid then
        local g = SafeUnitGUID(unit)
        if g and g == row.guid then
            return true
        end
    end

    -- Fallback to nameplate display name.
    local disp, dispBase = GetNameplateDisplayNames(unit)
    if row and row.fullName and disp and disp == row.fullName then
        return true
    end
    if row and row.name and dispBase and self.baseNameCounts and self.baseNameCounts[dispBase] == 1 and dispBase == row.name then
        return true
    end

    return false
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

    -- Unmap the other row from this recycled unit token
    other.unit = nil
    other._barsUnit = nil
    other._hpSB = nil
    other._pwrSB = nil
    other._hpSBAt = nil
    other._pwrSBAt = nil
    self.rowByUnit[unit] = nil

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
    return v, mx
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
        local cur, maxv = SafeStatusBarValues(candidates[i])
        if cur and maxv then return cur, maxv end
    end
    -- Last resort: scan child frames for the first StatusBar with values.
    if uf.GetChildren then
        local kids = { uf:GetChildren() }
        for i = 1, #kids do
            local k = kids[i]
            if k and k.GetObjectType then
                local okOT, ot = pcall(k.GetObjectType, k)
                if okOT and ot == "StatusBar" then
                    local cur, maxv = SafeStatusBarValues(k)
                    if cur and maxv then return cur, maxv end
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
        local cur, maxv = SafeStatusBarValues(sb)
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

local function ExtractClassFileFromScoreTuple(t)
    if type(t) ~= "table" then return nil end
    for i = 1, #t do
        local v = t[i]
        if type(v) == "string" and v ~= "" then
            if (RAID_CLASS_COLORS and RAID_CLASS_COLORS[v]) then
                return v
            end
            if (C_ClassColor and C_ClassColor.GetClassColor) then
                local ok, c = pcall(C_ClassColor.GetClassColor, v)
                if ok and c then
                    return v
                end
            end
        end
    end
    return nil
end

-- Prefer C_PvP.GetScoreInfo(i) (has GUID + classToken + spec/role on modern clients).
-- Fall back to legacy GetBattlefieldScore tuple parsing if needed (less reliable).
function BGE:BuildRosterFromScoreboard()
    wipe(self.roster)
    wipe(self.nameCounts)
    self:EnsurePIDMaps()
    wipe(self.fullNameCounts)
    wipe(self.baseNameCounts)
    local seenGuid = {}
    local seenFull = {}

    -- Stable roster ordering across frequent scoreboard refreshes.
    -- Scoreboard index order is NOT stable mid-match; without this, rows will reshuffle.
    self._rosterOrderSeq = self._rosterOrderSeq or 0
    self._rosterOrderByKey = self._rosterOrderByKey or {}

    local function NormalizeRole(role)
        local s = SafeToString(role)
        if type(s) == "string" then
            local up = s:upper()
            if up == "HEALER" or up == "DAMAGER" or up == "TANK" then
                return up
            end
            
            local n = tonumber(s)
            if n == 4 then return "HEALER" end
            if n == 2 then return "TANK" end
            if n == 1 or n == 8 then return "DAMAGER" end
        end
        return nil
    end

    local function RoleRank(role)
        if role == "TANK" then return 1 end
        if role == "HEALER" then return 2 end
        if role == "DAMAGER" then return 3 end
        return 4
    end

    local n = 0
    if _G.C_PvP and _G.C_PvP.GetScoreInfo then
        -- Use match faction when available (mercenary-safe).
        local myFactionIndex = nil
        if _G.C_PvP.GetActiveMatchFaction then
            local okF, f = pcall(_G.C_PvP.GetActiveMatchFaction)
            if okF and type(f) == "number" then
                myFactionIndex = NormalizeFactionIndex(f)
            end
        end
        if myFactionIndex == nil then
            -- Fallback: use "true" match faction for the player (mercenary-safe).
            -- UnitFactionGroup("player") reports your character's faction, not necessarily your BG team.
            myFactionIndex = GetUnitTrueFactionIndex("player")
        end
        local okN, nn = pcall(GetNumBattlefieldScores)
        n = (okN and nn) or 0

        -- If Blizzard APIs can't reliably tell our *match* faction (merc / cross-faction),
        -- derive it from the scoreboard row for the local player.
        if n > 0 then
            local pName, pRealm = nil, nil
            if UnitFullName then
                pName, pRealm = UnitFullName("player")
            else
                pName = UnitName and UnitName("player") or nil
                pRealm = GetRealmName and GetRealmName() or nil
            end
            local pFull = (pName and pRealm and (pName .. "-" .. pRealm)) or pName
            if pName then
                for ii = 1, n do
                    local okP, infoP = pcall(_G.C_PvP.GetScoreInfo, ii)
                    if (not okP or type(infoP) ~= "table") and _G.GetBattlefieldScore then
                        local nameL, _, _, _, _, factionL = _G.GetBattlefieldScore(ii)
                        if nameL ~= nil then
                            infoP = infoP or {}
                            infoP.name = infoP.name or nameL
                            infoP.faction = infoP.faction or factionL
                            okP = true
                        end
                    end
                    if okP and type(infoP) == "table" then
                        local nFull = SafeNonEmptyString(infoP.name)
                        if nFull == pFull or nFull == pName then
                            if type(infoP.faction) == "number" then
                                myFactionIndex = NormalizeFactionIndex(infoP.faction)
                            end
                            break
                        end
                    end
                end
            end
        end

        for i = 1, n do
            local ok, info = pcall(_G.C_PvP.GetScoreInfo, i)
            -- BG start: GetScoreInfo can be nil/error for some indices. Don't drop the slot; use GetBattlefieldScore.
            if (not ok or type(info) ~= "table") and _G.GetBattlefieldScore then
                local nameL, _, _, _, _, factionL, rankL, raceL, _, classTokenL, _, _, _, _, _, specNameL = _G.GetBattlefieldScore(i)
                if nameL or classTokenL or factionL ~= nil then
                    info = info or {}
                    info.name       = info.name       or nameL
                    info.classToken = info.classToken or classTokenL
                    info.raceName   = info.raceName   or raceL
                    info.talentSpec = info.talentSpec or specNameL
                    info.honorLevel = info.honorLevel or rankL
                    info.faction    = info.faction    or factionL
                    ok = true
                end
            end
            if ok and type(info) == "table" then
                local isFriendly = false
                local myFI = NormalizeFactionIndex(myFactionIndex)
                local fi   = NormalizeFactionIndex(info.faction)

                -- If C_PvP.GetScoreInfo faction is secret/unreadable, use GetBattlefieldScore faction instead.
                if (not fi) and _G.GetBattlefieldScore then
                    local _, _, _, _, _, factionL = _G.GetBattlefieldScore(i)
                    if factionL ~= nil then
                        fi = NormalizeFactionIndex(factionL)
                    end
                end

                if myFI and fi and fi == myFI then
                    isFriendly = true
                end

                if not isFriendly then
                    local guid = SafeToString(info.guid)
                    local full = SafeNonEmptyString(info.name)
                    local classToken = SafeNonEmptyString(info.classToken)
                    -- talentSpec is often a string; keep it for display if you want.
                    local specID = SafeNonEmptyString(info.talentSpec)
                    local role = NormalizeRole(info.roleAssigned)
                    local raceName = SafeNonEmptyString(info.raceName)
                    local honorLevel = tonumber(SafeToString(info.honorLevel)) or 0
                    -- PVPScoreInfo does not include level/sex (12.x); don't pretend it does.
                    local level = 0
                    local sex = 0
                    local factionIndex = fi or (NormalizeFactionIndex(info.faction)) or 0

                    -- If C_PvP.GetScoreInfo omitted/blocked fields, fall back to GetBattlefieldScore 
                    if (not full or not classToken) and _G.GetBattlefieldScore then
                        local nameL, _, _, _, _, factionL, rankL, raceL, _, classTokenL, _, _, _, _, _, specNameL = _G.GetBattlefieldScore(i)
                        if not full then full = SafeNonEmptyString(nameL) end
                        if not classToken then classToken = SafeNonEmptyString(classTokenL) end
                        if not raceName then raceName = SafeNonEmptyString(raceL) end
                        if not specID then specID = SafeNonEmptyString(specNameL) end
                        if honorLevel == 0 and rankL then honorLevel = tonumber(SafeToString(rankL)) or honorLevel end
                        if factionL ~= nil then factionIndex = NormalizeFactionIndex(factionL) end
                    end

                    local classID = (classToken and self.ClassTokenToID and self.ClassTokenToID[classToken]) or 0
                    local raceID = (raceName and self.RaceNameToID and self.RaceNameToID[raceName]) or 0
                    -- Fallback: derive role from specID if roleAssigned wasn't usable.
                    if not role then
                        local sid = tonumber(specID)
                        if sid and _G.GetSpecializationRoleByID then
                            local okR, r = pcall(_G.GetSpecializationRoleByID, sid)
                            if okR and type(r) == "string" and r ~= "" then
                                role = NormalizeRole(r)
                            end
                        end
                    end

                    if full then
                        -- Deduplicate: prefer GUID when we have it, otherwise dedupe by full name.
                        if (guid and seenGuid[guid]) or seenFull[full] then
                            -- skip duplicate row
                        else
                            if guid then seenGuid[guid] = true end
                            seenFull[full] = true

                        local okBase, base = pcall(function() return full:match("^[^-]+") end)
                        local name = (okBase and base) or full

                        -- Stable ordering key (prefer GUID, else full name).
                        local okey = guid or full
                        local ord = self._rosterOrderByKey[okey]
                        if not ord then
                            self._rosterOrderSeq = self._rosterOrderSeq + 1
                            ord = self._rosterOrderSeq
                            self._rosterOrderByKey[okey] = ord
                        end

                        -- Track duplicates correctly:
                        -- fullName is the true unique identifier across realms.
                        self.fullNameCounts[full] = (self.fullNameCounts[full] or 0) + 1
                        self.baseNameCounts[name] = (self.baseNameCounts[name] or 0) + 1
                        -- Keep old table for compatibility: treat it as base counts.
                        self.nameCounts[name] = self.baseNameCounts[name]
                        self.roster[#self.roster + 1] = {
                            _order = ord,
                            guid = guid,
                            fullName = full,
                            name = name,
                            classToken = classToken,
                            specID = specID,
                            role = role,
                            raceName = raceName,
                            raceID = raceID,
                            classID = classID,
                            faction = factionIndex,
                            -- level/sex are learned later from real unit tokens if needed
                            level = 0,
                            sex = 0,
                            honorLevel = honorLevel,
                        }
                        end
                    end
                end
            end
        end

        -- Apply deterministic ordering:
        -- 1) "Grouped (sorted)" -> TANK, HEALER, DAMAGER (then stable first-seen order)
        -- 2) "Single list"      -> stable first-seen order only (no mid-match reshuffles)
        local layout = GetSetting("bgeLayout", 1)
        local grouped = (layout == 2)
        table.sort(self.roster, function(a, b)
            if grouped then
                local ra, rb = RoleRank(a.role), RoleRank(b.role)
                if ra ~= rb then return ra < rb end
            end
            local oa, ob = tonumber(a._order) or 0, tonumber(b._order) or 0
            if oa ~= ob then return oa < ob end
            return (a.fullName or "") < (b.fullName or "")
        end)
        return
    end

    -- Legacy fallback (no GUID): keep existing class list behaviour.
    -- This won't be able to GUID-match nameplates, but it preserves old behaviour.
    self:RebuildScoreCache()
end

local function GetPlayerDB()
    -- Ensure SavedVariables are loaded (RatedStats wires Database in LoadData()).
    if type(_G.LoadData) == "function" then
        pcall(_G.LoadData)
    end

    local RS = _G.RSTATS
    if not RS or not RS.Database then return nil end
    local key = UnitName("player") .. "-" .. GetRealmName()
    local db = RS.Database[key]
    if not db then return nil end
    db.settings = db.settings or {}
    return db
end


-- Per-enemy-team-size layout profiles.
--
-- Profiles:
--   Rated (8v8)  -> bgeRated*
--   10v10        -> bge10*
--   15v15        -> bge15*
--   >15v15       -> bgeLarge*
--
-- These replace the old single set of layout sliders.
--
-- Backwards compatibility: if the new per-profile key isn't set yet,
-- fall back to the legacy single-key (e.g. bgeRowWidth).
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
    row:SetAttribute("type1", "macro")
    row:SetAttribute("macrotext", nil)
    -- IMPORTANT: roster rows are not "nameplate index" rows.
    -- We only set the unit attribute once we have a GUID->nameplate match.
    row:SetAttribute("unit", nil)
    row.plateIndex = nil

    -- PostClick: keep secure macro targeting intact, then apply selection highlight.
    row:HookScript("PostClick", function(self, button)
        local bge = _G.RSTATS_BGE
        if bge and bge.SetSelectedRow then
            bge:SetSelectedRow(self)
        end
    end)

    -- IMPORTANT: do NOT SetScript("OnClick") on a secure action button; it breaks secure targeting.
    -- Use PostClick so the secure target action runs, then we do selection/highlight.
    row:HookScript("PostClick", function(self, button)
        local bge = _G.RSTATS_BGE
        if not bge then return end

        bge:SetSelectedRow(self)

        -- Keep the secure unit attribute in sync out of combat (combat lockdown blocks SetAttribute).
        if button == "LeftButton" and not self._preview and self.unit and not InLockdown() then
            local cur = self:GetAttribute("unit")
            if cur ~= self.unit then
                self:SetAttribute("unit", self.unit)
            end
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
    row.unit = nil -- runtime unit token passed by events, also equals "nameplateX"
    row.name = nil
    row.fullName = nil
    row.achievIconTex = nil
    row.classFile = nil
    row.role = nil
    row.specID = nil
    row._preview = false
    row._lastNameTry = 0

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
    -- If no target, clear highlight.
    if not UnitExists("target") then
        self:SetSelectedRow(nil)
        return
    end

    -- 1) Best path: unit-token match, but scrub API returns (they can be secret booleans).
    for _, row in ipairs(self.rows or {}) do
        if row and not row._preview then
            local u = row.unit
            if type(u) == "string" and u ~= "" then
                local okE, ex = pcall(UnitExists, u)
                if okE then
                    if scrubsecretvalues then ex = scrubsecretvalues(ex) end
                    if ex == true then
                        local okI, same = pcall(UnitIsUnit, "target", u)
                        if okI then
                            if scrubsecretvalues then same = scrubsecretvalues(same) end
                            if same == true then
                                self:SetSelectedRow(row)
                                return
                            end
                        end
                    end
                end
            end
        end
    end

    -- 2) Fallback: GUID match (guarded).
    local guid = SafeUnitGUID("target")
    if scrubsecretvalues then
        guid = scrubsecretvalues(guid)
    end
    if type(guid) == "string" and guid ~= "" and self.rowByGuid then
        local ok, hit = pcall(function() return self.rowByGuid[guid] end)
        if ok and hit then
            self:SetSelectedRow(hit)
            return
        end
    end

    -- 3) Last resort: name match, but scrub secrets before any boolean tests.
    if self.rowByFullName then
        local okN, full = pcall(GetUnitName, "target", true)
        if okN then
            if scrubsecretvalues then full = scrubsecretvalues(full) end
            if type(full) == "string" and full ~= "" then
                local okR, hit = pcall(function() return self.rowByFullName[full] end)
                if okR and hit then
                    self:SetSelectedRow(hit)
                    return
                end
            end
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
                -- BG roster rows: unit is assigned by GUID->nameplate match.
                row:SetAttribute("unit", nil)
            end
        end
    end
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

local function SetRoleTexture(tex, role)
    if not tex then return false end
    if not role or role == "" then
        tex:Hide()
        return false
    end

    if tex.SetAtlas and _G.GetMicroIconForRole then
        local okAtlas, atlas = pcall(_G.GetMicroIconForRole, role)
        if okAtlas and type(atlas) == "string" then
            if _G.C_Texture and _G.C_Texture.GetAtlasInfo then
                local okInfo, info = pcall(_G.C_Texture.GetAtlasInfo, atlas)
                if okInfo and info then
                    local okSet = pcall(tex.SetAtlas, tex, atlas, true)
                    if okSet then
                        tex:SetTexCoord(0, 1, 0, 1)
                        tex:Show()
                        return true
                    end
                end
            else
                local okSet = pcall(tex.SetAtlas, tex, atlas, true)
                if okSet then
                    tex:SetTexCoord(0, 1, 0, 1)
                    tex:Show()
                    return true
                end
            end
        end
    end

    tex:Hide()
    return false
end

local function ExtractSpecIDFromScoreTuple(t)
    if type(t) ~= "table" then return nil end
    for i = #t, 1, -1 do
        local v = t[i]
        if type(v) == "number" and v > 0 and v < 10000 then
            -- Validate as a specID by seeing if WoW can name it.
            if _G.GetSpecializationNameForSpecID then
                local ok, specName = pcall(_G.GetSpecializationNameForSpecID, v)
                if ok and type(specName) == "string" and specName ~= "" then
                    return v
                end
            elseif _G.GetSpecializationInfoByID then
                local ok, a, b = pcall(_G.GetSpecializationInfoByID, v)
                -- If it didn't error, it's almost certainly a specID.
                if ok then
                    return v
                end
            end
        end
    end
    return nil
end

function BGE:RebuildScoreCache()
    wipe(self.scoreCache)
    wipe(self.scoreClassList)

    if not _G.GetNumBattlefieldScores or not _G.GetBattlefieldScore then
        self.scoreCacheAt = GetTime()
        return
    end

    local n = GetNumBattlefieldScores() or 0
    for i = 1, n do
        local tuple = { GetBattlefieldScore(i) }
        local nameRealm = tuple[1]
        if type(nameRealm) == "string" and nameRealm ~= "" then
            local base = nameRealm:match("^[^-]+") or nameRealm
            local rec = self.scoreCache[base]
            if not rec then
                rec = { count = 0 }
                self.scoreCache[base] = rec
            end
            rec.count = rec.count + 1

            -- Capture class token from the scoreboard (for BG start seeding)
            local classFile = ExtractClassFileFromScoreTuple(tuple)
            if classFile then
                rec.classFile = rec.classFile or classFile
                self.scoreClassList[#self.scoreClassList + 1] = classFile
            end

            -- Only store role data if currently unique.
            if rec.count == 1 then
                local specID = ExtractSpecIDFromScoreTuple(tuple)
                if specID and _G.GetSpecializationRoleByID then
                    local ok, role = pcall(_G.GetSpecializationRoleByID, specID)
                    if ok and type(role) == "string" and role ~= "" then
                        rec.role = role
                    else
                        rec.role = nil
                    end
                else
                    rec.role = nil
                end
            else
                -- Duplicate name: disable role display for that base name.
                rec.role = nil
            end
        end
    end

    self.scoreCacheAt = GetTime()

    -- Apply to any visible live rows immediately.
    for _, row in ipairs(self.rows) do
        if row and row:IsShown() and not row._preview then
            self:UpdateRoleIcon(row)
        end
    end
end

function BGE:ApplyRowMacroTarget(row)
    if not row or row._preview then return end

    -- Prefer realm-qualified targeting 
    local targetName = row.fullName or row.name
    if type(targetName) ~= "string" or targetName == "" then
        if not InLockdown() then
            row:SetAttribute("macrotext", nil)
        else
            self.pendingMacroByRow = self.pendingMacroByRow or {}
            self.pendingMacroByRow[row] = nil
        end
        return
    end

    -- /targetexact is the reliable method here (unit tokens on enemy nameplates are not)
    local macro = "/cleartarget\n/targetexact " .. targetName

    if not InLockdown() then
        row:SetAttribute("macrotext", macro)
    else
        self.pendingMacroByRow = self.pendingMacroByRow or {}
        self.pendingMacroByRow[row] = macro
    end
end

function BGE:HasUnresolvedSeededRows()
    -- If we haven't successfully seeded anything yet, we definitely still need reseeds.
    if not self._seededThisBG or not self._seedCount or self._seedCount == 0 then
        return true
    end

    for i = 1, self._seedCount do
        local row = self.rows and self.rows[i] or nil
        if not row or not row._seenIdentity then
            return true
        end

        local nameOK = (type(row.name) == "string" and row.name ~= "")
        local classOK = (type(row.classFile) == "string" and row.classFile ~= "")
        local idOK =
            (type(row.guid) == "string" and row.guid ~= "") or
            (type(row.fullName) == "string" and row.fullName ~= "")

        if not (nameOK and classOK and idOK) then
            return true
        end
    end

    return false
end

function BGE:SeedRowsFromScoreboard()
    -- BG only (arena uses arena1..arena5)
    if self._mode == "arena" then return end
    if not IsInPVPInstance() then return end

    -- Throttle: UPDATE_BATTLEFIELD_SCORE can fire very frequently in busy fights.
    local now = GetTime()
    local minGap = (self._matchStarted and 5.0) or 1.0
    if self._lastSeedAt and (now - self._lastSeedAt) < minGap then
        return
    end
    self._lastSeedAt = now

    -- Build roster from the scoreboard.
    self:BuildRosterFromScoreboard()

    -- Mid-match join: don't stop reseeding just because the currently seeded rows look "resolved".
    -- Only stop once the roster has reached the expected team size for this map.
    if self._matchStarted and self._seededThisBG and (not self:HasUnresolvedSeededRows()) then
        local rosterN = (self.roster and #self.roster) or 0

        -- IMPORTANT: do not default expected=10 here.
        -- If we guess 10 too early in a 15v15, we permanently stop at 10.
        local expected = self._expectedBGTeamSize
        if not expected then
            local mapID = nil
            if C_Map and C_Map.GetBestMapForUnit then
                local okM, mid = pcall(C_Map.GetBestMapForUnit, "player")
                if okM then mapID = mid end
            end

            local maxPlayers = nil
            -- Prefer resolved maxPlayers first.
            if mapID and C_PvP and C_PvP.GetNumBattlegroundTypes and C_PvP.GetBattlegroundInfo then
                local okN, tN = pcall(C_PvP.GetNumBattlegroundTypes)
                if okN and type(tN) == "number" then
                    for idx = 1, tN do
                        local okI, bi = pcall(C_PvP.GetBattlegroundInfo, idx)
                        if okI and bi and bi.mapID == mapID and type(bi.maxPlayers) == "number" then
                            maxPlayers = bi.maxPlayers
                            break
                        end
                    end
                end
            end

            if maxPlayers and maxPlayers > 15 then
                expected = 40
            elseif maxPlayers and maxPlayers == 15 then
                expected = 15
            elseif maxPlayers and maxPlayers == 10 then
                expected = 10
            -- Fallback only if maxPlayers not resolved:
            elseif mapID == 1366 or mapID == 112 or mapID == 968 then
                expected = 15
            end

            -- Fallback: infer from scoreboard total once it has populated.
            -- GetNumBattlefieldScores is BOTH teams.
            if not expected and _G.GetNumBattlefieldScores then
                local enteredAt = self._enteredBGAt or now
                local age = now - enteredAt
                local okT, total = pcall(_G.GetNumBattlefieldScores)
                total = (okT and type(total) == "number") and total or 0

                if total >= 60 then
                    expected = 40
                elseif total >= 26 then
                    expected = 15
                elseif age >= 25 and rosterN >= 10 then
                    -- Only decide 10v10 once we've had time for the scoreboard to fill.
                    expected = 10
                end
            end

            if expected then
                self._expectedBGTeamSize = expected
            end
        end

        if expected and rosterN >= expected then
            return
        end
        -- roster still short: allow reseed to continue
    end

    -- BG start AND active-join: scoreboard feed often populates late. If roster is short, retry quickly.
    local enteredAt = self._enteredBGAt or now
    local justEntered = (now - enteredAt) <= 20
    if (_G.C_Timer and _G.C_Timer.After) and ((not self._matchStarted) or justEntered) then
        local expected = self._expectedBGTeamSize or self._expectedBGTeamSizeGuess
        -- last resort: if expected still unknown, use current display capacity (GUESS ONLY)
        if not expected then
            local cols = GetSetting("bgeColumns", 1)
            local rowsPerCol = GetSetting("bgeRowsPerCol", 20)
            local want = math.floor((cols or 1) * (rowsPerCol or 20))
            if want > 0 then
                expected = math.min(self.maxPlates or 40, want)
                self._expectedBGTeamSizeGuess = expected
            end
        end

        if expected and self.roster and #self.roster < expected then
            if not self._seedRetryPending then
                self._seedRetryPending = true
                self._seedStartRetries = (self._seedStartRetries or 0) + 1
                if self._seedStartRetries <= 40 then
                    _G.C_Timer.After(0.5, function()
                        -- clear pending first to avoid getting stuck if we bail early
                        BGE._seedRetryPending = false
                        BGE._lastSeedAt = nil -- bypass throttle for this start-only retry
                        if _G.RequestBattlefieldScoreData then
                            pcall(_G.RequestBattlefieldScoreData)
                        end
                        BGE:SeedRowsFromScoreboard()
                    end)
                else
                    self._seedRetryPending = false
                end
            end
        end
    end

    -- Preserve live nameplate bindings across reseeds.
    -- Roster rows are stable by GUID; nameplates do NOT reliably refire ADDED events mid-match.
    local oldUnitByGuid = {}
    local oldUnitByFullName = {}
    local oldUnitByBaseName = {}
    if self.rowByUnit then
        for unit, r in pairs(self.rowByUnit) do
            if r and UnitExists(unit) then
                if r.guid then
                    oldUnitByGuid[r.guid] = unit
                end
                if r.fullName then
                    oldUnitByFullName[r.fullName] = unit
                end
                -- Only keep base-name preservation when unique (same rule as binding).
                if r.name and self.baseNameCounts and self.baseNameCounts[r.name] == 1 then
                    oldUnitByBaseName[r.name] = unit
                end
            end
        end
    end

    -- Full reseed every tick: scoreboard order can shift while players join/leave.
    -- Append-only seeding WILL drift and duplicate identities.
    wipe(self.rowByGuid)
    wipe(self.rowByName)
    wipe(self.rowByFullName)
    wipe(self.rowByBaseName)
    wipe(self.rowByPID)
    wipe(self.pidCounts)
    wipe(self.rowByPIDNoRace)
    wipe(self.pidNoRaceCounts)
    wipe(self.rowByPIDLoose)
    wipe(self.pidLooseCounts)

    -- Rebuild unit bindings from preserved GUID matches where possible.
    wipe(self.rowByUnit)
    wipe(self.pendingUnitByGuid)
    wipe(self.pendingUnitByRow)

    local rosterN = (self.roster and #self.roster) or 0
    local max = math.min(self.maxPlates, rosterN)

    -- Clear any unused rows (players left / not yet present).
    for i = max + 1, self.maxPlates do
        local row = self.rows[i]
        if row and not row._preview then
            if not InLockdown() then
                row:SetAttribute("unit", nil)
            end
            self:ReleaseRow(row)
            row._seenIdentity = nil
            row:SetAlpha(0)
        end
    end

    if max == 0 then
        self._seededThisBG = false
        self._seedCount = 0
        self._expectedBGTeamSize = nil
        self._expectedBGTeamSizeGuess = nil
        self._seedStartRetries = nil
        self._seedRetryPending = nil
        self:UpdateRowVisibilities()
        return
    end

    -- Seed rows 1..max from roster.
    for i = 1, max do
        local row = self.rows[i]
        local rec = self.roster[i]
        if row and rec and not row._preview then
            local prevGuid = row.guid
            local prevFull = row.fullName

            row.guid = rec.guid
            row.name = rec.name
            row.fullName = rec.fullName
            self:ApplyRowMacroTarget(row)

            local identityChanged =
                (prevGuid and row.guid and prevGuid ~= row.guid) or
                (not prevGuid and prevFull and row.fullName and prevFull ~= row.fullName)

            -- Only reset binding when this row represents a different player.
            if identityChanged then
                row.unit = nil
                if not InLockdown() then
                    row:SetAttribute("unit", nil)
                end
            end

            -- Only clear text if this row now represents a different player.
            if identityChanged then
--                row.hpText:SetText("")
--                row._lastHpTextAt = nil
            end

            -- Achievements: seed once per unique player (per BG), not every reseed tick.
            self.achievCache = self.achievCache or {}
            local akey = row.fullName or row.name
            local cached = akey and self.achievCache[akey] or nil
            if cached == nil then
                local tex, txt, tint = GetIconTextureForEnemyName(row.fullName, row.name)
                cached = { tex = tex, txt = txt, tint = tint }
                if akey then
                    self.achievCache[akey] = cached
                end
            end
            local hadAchTex = row.achievIconTex
            row.achievIconTex = cached and cached.tex or nil
            row.achievText    = cached and cached.txt or nil
            row.achievTint    = cached and cached.tint or nil

            -- If Achievements became available after initial layout, force a relayout so the icon is placed.
            if (not hadAchTex) and row.achievIconTex then
                if InLockdown() then
                    self._anchorsDirty = true
                else
                    self:ApplyRowLayout(row)
                end
            end

            row.raceID = rec.raceID
            row.classID = rec.classID
            row.faction = rec.faction
            row.level = 0
            row.sex = 0
            row.honorLevel = rec.honorLevel
            row.classFile = rec.classToken
            row.specID = rec.specID
            row.role = rec.role
            row._seeded = true

            -- Restore prior live unit binding if we had one for this GUID.
            local u = nil
            if row.guid and oldUnitByGuid[row.guid] then
                u = oldUnitByGuid[row.guid]
            elseif row.fullName and oldUnitByFullName[row.fullName] then
                u = oldUnitByFullName[row.fullName]
            elseif row.name and self.baseNameCounts and self.baseNameCounts[row.name] == 1 and oldUnitByBaseName[row.name] then
                u = oldUnitByBaseName[row.name]
            end
            if u and UnitExists(u) and not UnitIsFriend("player", u) then
                row.unit = u
                self.rowByUnit[u] = row
                if not InLockdown() then
                    row:SetAttribute("unit", u)
                else
                    self.pendingUnitByRow[row] = u
                end
                -- Force a snap update now that the binding is restored.
                self:UpdateHealth(row, u)
                self:UpdatePower(row, u)
            else
                -- If we already have a working alt unit (raidXtarget), keep it instead of dropping the binding.
                if row._altUnit and UnitExists(row._altUnit) then
                    row.unit = row._altUnit
                    self.rowByUnit[row._altUnit] = row
                    if not InLockdown() then
                        row:SetAttribute("unit", row._altUnit)
                    else
                        self.pendingUnitByRow[row] = row._altUnit
                    end
                    self:UpdateHealth(row, row._altUnit)
                    self:UpdatePower(row, row._altUnit)
                else
                    row.unit = nil
                    if not InLockdown() then
                        row:SetAttribute("unit", nil)
                    end
                end
            end

            -- GUID->row lookup
            if row.guid then
                self.rowByGuid[row.guid] = row
            end

            -- PID map (unique-only)
            local pid = CalculatePIDFull(row.raceID, row.classID, row.level, row.faction, row.sex, row.honorLevel)
            row.pid = pid
            DPrint("SEEDPID_" .. tostring(i), "SEED row["..i.."] name="..tostring(row.name or "nil").." pid="..tostring(pid))
            if pid and pid > 0 then
                local c = (self.pidCounts[pid] or 0) + 1
                self.pidCounts[pid] = c
                if c == 1 then
                    self.rowByPID[pid] = row
                else
                    self.rowByPID[pid] = nil
                end
            end

            -- No-race PID (unique-only) for Mercenary mode fallback.
            -- In Merc mode, UnitRace(unit) can report the *visual* race, which may not match the scoreboard race.
            local pidNR = CalculatePIDFull(0, row.classID, row.level, row.faction, row.sex, row.honorLevel)
            row.pidNoRace = pidNR
            if pidNR and pidNR > 0 then
                local cNR = (self.pidNoRaceCounts[pidNR] or 0) + 1
                self.pidNoRaceCounts[pidNR] = cNR
                if cNR == 1 then
                    self.rowByPIDNoRace[pidNR] = row
                else
                    self.rowByPIDNoRace[pidNR] = nil
                end
            end

            -- Loose PID (no honor) for nameplate units that report honor=0
            local pidL = CalculatePIDLooseFull(row.raceID, row.classID, row.level, row.faction, row.sex)
            row.pidLoose = pidL
            if pidL and pidL > 0 then
                local cL = (self.pidLooseCounts[pidL] or 0) + 1
                self.pidLooseCounts[pidL] = cL
                if cL == 1 then
                    self.rowByPIDLoose[pidL] = row
                else
                    self.rowByPIDLoose[pidL] = nil
                end
            end

            -- Display: base name only (no -realm)
            row.nameText:SetText(row.name)
            row.nameText:SetTextColor(RS_TEXT_R, RS_TEXT_G, RS_TEXT_B)

            -- Respect current OOR state (don't force "in range" visuals during reseeds).
            ApplyClassAlpha(row, (row._outOfRange and CLASS_ALPHA_OOR) or CLASS_ALPHA_ACTIVE)

            -- Do NOT clobber live HP/text during periodic reseeds (every ~5s).
            if not row.unit then
                pcall(row.hp.SetMinMaxValues, row.hp, 0, 1)
                pcall(row.hp.SetValue, row.hp, 1)
                -- keep existing text unless identity changed above
            end
            UpdateNameClipToHPFill(row)

            row._seenIdentity = true
            -- IMPORTANT: do not SetAlpha() here.
            -- UpdateRowVisibilities() will apply the correct alpha (prep / in-range / OOR / player-dead).

            -- Primary bind key: fullName (safe across realms)
            if row.fullName and self.fullNameCounts and self.fullNameCounts[row.fullName] == 1 then
                self.rowByFullName[row.fullName] = row
                self.rowByName[row.fullName] = row
            end
            -- Secondary bind key: base name only when unique
            if row.name and self.baseNameCounts and self.baseNameCounts[row.name] == 1 then
                self.rowByBaseName[row.name] = row
            end

            self:UpdateRoleIcon(row)
        end
    end

    self._seededThisBG = true
    self._seedCount = max

    self:DebugSeededGuidKeys(max)
    if GetSetting("bgeDebug", false) then
        local nPid = 0
        for _ in pairs(self.rowByPID or {}) do nPid = nPid + 1 end
        DPrint("SEEDPID", "SEED rowByPID.count=" .. tostring(nPid))
    end

    -- After reseed, immediately bind any visible nameplates to rows.
    self:ScanNameplatesForGuidBindings()
    self:UpdateRowVisibilities()
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
    -- We want: solid rows during the prep phase, then once the match truly starts (gates open),
    -- enable out-of-range dimming and keep it enabled until we leave the PvP instance.
    local inPvp = IsInPVPInstance()
    if not inPvp then
        self._matchStarted = false
        self._oorEnabled = false
        self.achievCache = nil -- reset per BG
        return
    end

    self._matchStarted = self:IsMatchStarted()
    if self._matchStarted then
        self._oorEnabled = true
    end
end

-- Schedule a reseed soon, but collapse bursts of score updates into one call.
function BGE:ScheduleSeedFromScoreboard()
    if self._seedPending then return end
    self._seedPending = true
    C_Timer.After(0.5, function()
        self._seedPending = false
        if not IsInPVPInstance() or self._mode == "arena" or not GetSetting("bgeEnabled", true) then return end
        if _G.RequestBattlefieldScoreData then
            pcall(_G.RequestBattlefieldScoreData)
        end
        self:RebuildScoreCache()
        self:SeedRowsFromScoreboard()
    end)
end

-- Short BG-entry warmup: scoreboard often starts at 0 until it gets a push.
function BGE:StartScoreWarmup()
    if self._scoreWarmupTicker then return end
    self._scoreWarmupStartedAt = GetTime()
    -- Long-lived keepalive: BGs can be joined late and score data can lag.
    -- Keep it LOW frequency to avoid combat hitching.
    self._scoreWarmupTicker = C_Timer.NewTicker(5, function()
        if not IsInPVPInstance() or self._mode == "arena" or not GetSetting("bgeEnabled", true) then
            self:StopScoreWarmup()
            return
        end

        -- If match started and everything is resolved AND we have filled our display capacity, stop.
        local cols = GetSetting("bgeColumns", 1)
        local rowsPerCol = GetSetting("bgeRowsPerCol", 20)
        local want = math.floor((cols or 1) * (rowsPerCol or 20))
        if want < 1 then want = 1 end
        if want > (self.maxPlates or 40) then want = (self.maxPlates or 40) end
        local rosterN = (self.roster and #self.roster) or 0
        local expected = self._expectedBGTeamSize or self._expectedBGTeamSizeGuess
        local startedAt = self._scoreWarmupStartedAt or GetTime()
        local age = GetTime() - startedAt

        -- Stop once resolved; do not require roster to reach "want" (settings can exceed actual team size).
        if self._matchStarted and self._seededThisBG and (not self:HasUnresolvedSeededRows()) then
            if (expected and rosterN >= expected) or (age >= 90) then
                self:StopScoreWarmup()
                return
            end
        end

        if self._matchStarted and self._seededThisBG and (not self:HasUnresolvedSeededRows()) and rosterN >= want then
            self:StopScoreWarmup()
            return
        end

        -- If match started and we're in combat, don't hammer the scoreboard unless we still need resolution.
        if self._matchStarted and self._seededThisBG and UnitAffectingCombat and UnitAffectingCombat("player") then
            return
        end

        if _G.RequestBattlefieldScoreData then
            pcall(_G.RequestBattlefieldScoreData)
        end
        self:RebuildScoreCache()
        self:SeedRowsFromScoreboard()
    end)
end

function BGE:StopScoreWarmup()
    if self._scoreWarmupTicker then
        self._scoreWarmupTicker:Cancel()
        self._scoreWarmupTicker = nil
    end
    self._scoreWarmupStartedAt = nil
end

function BGE:UpdateRoleIcon(row)
    if not row or not row.roleIcon then return end
    if not row.name then
        return
    end

    -- Prefer roster role
    if row.role then
        if SetRoleTexture(row.roleIcon, row.role) then
            row.roleIcon:Show()
        else
            row.roleIcon:Hide()
        end
        return
    end

    local rec = self.scoreCache and self.scoreCache[row.name] or nil
    if not rec or rec.count ~= 1 or not rec.role then
        row.roleIcon:Hide()
        return
    end

    if SetRoleTexture(row.roleIcon, rec.role) then
        row.roleIcon:Show()
    else
        row.roleIcon:Hide()
    end
end

UpdateNameClipToHPFill = function(row)
    if not row or not row.hp or not row.nameText then return end

    -- Clamp name width to the *filled* portion of the HP bar (class colour).
    -- IMPORTANT: In Midnight builds, geometry getters can return "secret" values.
    -- Never do arithmetic on these directly.
    local function SafeNumber(v)
        if type(v) ~= "number" then return nil end
        if issecretvalue and issecretvalue(v) then return nil end
        return v
    end

    local tex = row.hp.GetStatusBarTexture and row.hp:GetStatusBarTexture() or nil

    local hpLeft
    if row.hp.GetLeft then
        local ok, v = pcall(row.hp.GetLeft, row.hp)
        if ok then hpLeft = SafeNumber(v) end
    end

    local fillRight
    if tex and tex.GetRight then
        local ok, v = pcall(tex.GetRight, tex)
        if ok then fillRight = SafeNumber(v) end
    end

    if not hpLeft or not fillRight then
        -- Fallback: clamp to full HP width if we can't read texture geometry.
        local w = row.hp.GetWidth and row.hp:GetWidth() or 0
        if type(w) == "number" and w > 0 then
            row.nameText:SetWidth(math.max(0, w - 6))
        end
        return
    end

    local okW, fillW = pcall(function() return fillRight - hpLeft end)
    if not okW or type(fillW) ~= "number" or (issecretvalue and issecretvalue(fillW)) then
        local w = row.hp.GetWidth and row.hp:GetWidth() or 0
        if type(w) == "number" and w > 0 then
            row.nameText:SetWidth(math.max(0, w - 6))
        end
        return
    end
    if fillW < 0 then fillW = 0 end

    -- left inset matches ApplyRowLayout (4) + a little safety
    row.nameText:SetWidth(math.max(0, fillW - 6))
end

function BGE:EnsurePreviewRows()
    if not self.frame then return end
    if not self.rows or not self.rows[1] then return end

    if IsInPVPInstance() then
        self._enteredBGAt = self._enteredBGAt or GetTime()
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

    -- Use the pre-created secure rows (1..maxPlates). Preview shows 1..want.
    for i = 1, want do
        local rec = PREVIEW_ROSTER[i]
        local row = self.rows[i]
        if not row then return end
        self.previewRows[i] = row

        row._preview = true
        row.unit = nil
        row.name = rec.name
        row.fullName = nil
        row.achievIconTex = nil
        row.achievText = nil
        row.achievTint = nil

        -- Preview: if name includes realm, store it as fullName and keep base name in row.name
        if type(rec.name) == "string" then
            local n, r = rec.name:match("^([^-]+)%-(.+)$")
            if n and r then
                row.fullName = rec.name
                row.name = n
            end
        end
        row.classFile = rec.classFile
        row.role = rec.role

        local r, g, b = GetClassRGB(rec.classFile)
        row.bg:SetColorTexture(0, 0, 0, 0.35)
        row.hp:SetStatusBarColor(r, g, b, 0.85)

        -- Dummy values purely to show the bars
        row.hp:SetMinMaxValues(0, 100)
        local v = 82 - (i * 3 % 30)
        row.hp:SetValue(v)
        local mode = GetSetting("bgeHealthTextMode", 2)
        row.hpText:SetText(FormatHealthText(v, 100, mode))
        row.nameText:SetText(rec.name)
        -- Preview text stays Rated Stats colour (not class colour).
        row.nameText:SetTextColor(RS_TEXT_R, RS_TEXT_G, RS_TEXT_B)
        row.hpText:SetTextColor(RS_TEXT_R, RS_TEXT_G, RS_TEXT_B)
        -- Preview: show role icon from the preview roster (not scoreboard).
        if rec.role and SetRoleTexture(row.roleIcon, rec.role) then
            row.roleIcon:Show()
        else
            row.roleIcon:Hide()
        end

        if GetSetting("bgeShowPower", true) then
            row.power:SetMinMaxValues(0, 100)
            row.power:SetValue(65 - (i * 4 % 40))
            row.power:SetStatusBarColor(0.0, 0.55, 1.0, 0.9) -- mana-blue for preview
            row.power:Show()
        else
            row.power:Hide()
        end

        UpdateNameClipToHPFill(row)
        row:SetAlpha(1)
    end

    -- Hide all remaining rows while previewing (keep them reserved for PvP).
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
            -- If an alt unit token goes stale, drop it so OOR logic behaves.
            if row._altUnit and (not UnitExists(row._altUnit) or UnitIsFriend("player", row._altUnit)) then
                row._altUnit = nil
            end

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
                elseif row.unit and UnitExists(row.unit) and not UnitIsFriend("player", row.unit) then
                    row._outOfRange = false
                    ApplyClassAlpha(row, CLASS_ALPHA_ACTIVE)
                    row:SetAlpha(ROW_ALPHA_ACTIVE)

                else
                    row._outOfRange = true
                    ApplyClassAlpha(row, CLASS_ALPHA_OOR)
                    row:SetAlpha(ROW_ALPHA_OOR)
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

    row.unit = nil
    row.guid = nil
    row.name = nil
    row.fullName = nil
    row.achievIconTex = nil
    row.achievText = nil
    row.achievTint = nil
    row.classFile = nil
    row.role = nil
    row.specID = nil
    row._seeded = nil
--    row.hpText:SetText("")
    row.nameText:SetText("")
    if row.roleIcon then row.roleIcon:Hide() end
    row.hp:SetMinMaxValues(0, 1)
    row.hp:SetValue(0)
    row.power:SetMinMaxValues(0, 1)
    row.power:SetValue(0)
    row.power:Hide()
    row.bg:SetColorTexture(0, 0, 0, 0.35)
    -- Never Hide/Show secure rows. Alpha-only.
    row:SetAlpha(0)
end

function BGE:UpdateIdentity(row, unit)
    if not UnitExists(unit) then return end
    -- Don't deadlock on UnitIsEnemy being nil/false right after NAME_PLATE_UNIT_ADDED.
    -- We only hard-skip confirmed friendlies.
    if UnitIsFriend("player", unit) then return end

    -- Prefer GUID -> scoreboard identity (avoids secret UnitName issues on nameplates).
    if not row.guid then
        row.guid = SafeUnitGUID(unit)
    end

    local name, classFile
    if row.guid and _G.C_PvP and _G.C_PvP.GetScoreInfoByPlayerGuid then
        local okInfo, info = pcall(_G.C_PvP.GetScoreInfoByPlayerGuid, row.guid)
        if okInfo and type(info) == "table" then
            local full = SafeNonEmptyString(info.name)
            if full then
                row.fullName = full
                local okBase, base = pcall(function() return full:match("^[^-]+") end)
                name = (okBase and base) or full
            end
            classFile = SafeNonEmptyString(info.classToken)
        end
    end

    -- Fallback to UnitName/UnitClass only if scoreboard lookup failed.
    if not name then
        name = SafeUnitName(unit)
    end
    local classLoc
    if not classFile then
        classLoc, classFile = SafeUnitClass(unit)
    else
        classLoc = nil
    end

    if name then
        row.name = name
        row.nameText:SetText(name)
        row._seenIdentity = true
        row._seedClass = nil
    end

    local classAlpha = (row and row._outOfRange) and CLASS_ALPHA_OOR or CLASS_ALPHA_ACTIVE

    if classFile then
        row.classFile = classFile
        local r, g, b = GetClassRGB(classFile)
        row.bg:SetColorTexture(0, 0, 0, 0.35)
        row.hp:SetStatusBarColor(r, g, b, classAlpha)
        row._seenIdentity = true
    else
        -- If we don't have a class token yet but we *do* have localized class,
        -- keep going (don't treat as failure). Colouring waits for classFile.
        -- (Optional) you can set name text to classLoc if name is still missing,
        -- but keep it minimal: we just avoid blocking updates here.
        if row._seedClass and not row.classFile then
            row.classFile = row._seedClass
        end
        -- Don't force "in-range" colouring here; visibility decides alpha.
        -- This prevents periodic scoreboard reseeds from clobbering OOR/dead visuals mid-fight.
        local classAlpha = (row._outOfRange and CLASS_ALPHA_OOR) or CLASS_ALPHA_ACTIVE
        ApplyClassAlpha(row, classAlpha)
    end
    UpdateNameClipToHPFill(row)

    -- Role icon from scoreboard if unique base-name match.
    self:UpdateRoleIcon(row)

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

    -- If the icon just became available, we must re-run layout so it gets size/points
    -- and the name text shifts to make room.
    if (not hadAchTex) and iconTex then
        if InLockdown() then
            self._anchorsDirty = true
        else
            self:ApplyRowLayout(row)
        end
    end

    -- Keep secure macro target up-to-date when identity becomes known.
    self:ApplyRowMacroTarget(row)
end

-- Periodic retry: UnitName/UnitClass can be nil for a short time after ADDED/ARENA updates.
-- UNIT_NAME_UPDATE is not reliable for nameplate units, so we poll lightly while the unit exists.
function BGE:RetryMissingIdentities()
    if not self.frame then return end
    if not GetSetting("bgeEnabled", true) then return end
    if not IsInPVPInstance() and not GetSetting("bgePreview", false) then return end

    if self._mode == "arena" then
        for i = 1, self.arenaMax do
            local row = self.rows[i]
            if row and not row._preview and row.unit and UnitExists(row.unit) and not UnitIsFriend("player", row.unit) then
                if not row.name then
                    self:UpdateIdentity(row, row.unit)
                end
            end
        end
        return
    end

    for i = 1, self.maxPlates do
        local row = self.rows[i]
        if row and not row._preview and row.unit and UnitExists(row.unit) and not UnitIsFriend("player", row.unit) then
            if not row.name then
                DebugUnitSnapshot("RETRY", row.unit)
                self:UpdateIdentity(row, row.unit)
            end
        end
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

    for i = 1, self.maxPlates do
        local row = self.rows[i]
        local unit = row and row.unit
        if row and unit and UnitExists(unit) and not UnitIsFriend("player", unit) then
            -- These will fall back to reading the nameplate StatusBars when Unit* APIs are blocked.
            self:UpdateHealth(row, unit)
            self:UpdatePower(row, unit)
        end
    end
end

function BGE:UpdateHealth(row, unit)
    local cur, maxv

    -- If the unit is dead, show 0 instantly (prevents "full HP dead player" visuals).
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost(unit) then
        pcall(row.hp.SetMinMaxValues, row.hp, 0, 1)
        pcall(row.hp.SetValue, row.hp, 0)
        row.hpText:SetText("DEAD")
        return
    end

    -- Prefer reading the nameplate StatusBar when we can (this is the "works in BGs" path).
    -- If the update came from raidXtarget/etc but we also have a bound nameplate unit, use that for health read.
    local readUnit = unit
    if self._mode ~= "arena" and row and row.unit and IsNameplateUnit(row.unit) and UnitExists(row.unit) then
        readUnit = row.unit
    end

    -- Cache invalidation: nameplate frames get recycled.
    -- IMPORTANT: invalidate based on the unit we actually read bars from (readUnit), not the event token (unit).
    if row._barsUnit ~= readUnit then
        row._barsUnit = readUnit
        row._lastHpTextAt = nil
        row._lastClipAt = nil
        row._hpSB = nil
        -- Important: don't carry old text across recycled frames/units.
        pcall(row.hpText.SetText, row.hpText, "")
    end

    if self._mode ~= "arena" and IsNameplateUnit(readUnit) then
        cur, maxv = SafePlateHealth(readUnit)
    end
    if not cur or not maxv then
        cur, maxv = SafeUnitHealth(unit)
    end
    if not cur or not maxv then return end

    local mode = GetSetting("bgeHealthTextMode", 2)

    -- Keep bar updates simple (no fill-width math)
    pcall(row.hp.SetMinMaxValues, row.hp, 0, maxv)
    pcall(row.hp.SetValue, row.hp, cur)

    -- Throttle text updates (big perf win in busy fights)
    local now = GetTime()
    local lastT = row._lastHpTextAt or 0
    if (now - lastT) >= 0.50 then
        local txt

        -- Mode 3 ("%"): prefer UnitHealthPercent (0..100 via curve), else use nameplate fill geometry.
        if mode == 3 then
            -- 12.0+/Midnight: UnitHealthPercent can still be secret on hostile units.
            -- If it's non-secret (e.g. friendlies/self), use it to avoid any cur/max math.
            local pctV = nil

            -- 0) Try GUID API first (returns number percentHealth or nil)
            if UnitPercentHealthFromGUID and row and row.guid then
                local okG, gv = pcall(UnitPercentHealthFromGUID, row.guid)
                if okG then
                    local ng = tonumber(gv)
                    if ng == nil then
                    else
                        -- Some builds may return 0..1; scale if needed.
--                        if ng <= 1.001 then print("% from guid not %") end ## this was compared and is secret so blew up
                        pctV = ng
                    end
                end
            end

            if UnitHealthPercent then
                -- Prefer 0..100 via curve when available; otherwise API may return 0..1.
                local curve = (CurveConstants and CurveConstants.ScaleTo100) or nil
                local okP, v = pcall(UnitHealthPercent, readUnit, true, curve)
                local nv = okP and tonumber(v) or nil
                    if nv == nil then
                    else
                    -- If curve wasn't available, API may return 0..1; scale it.
--                    if nv <= 1.001 then print("% from health percent not %") end ## this was compared and is secret so blew up
                    pctV = nv
                end
            end

            if pctV ~= nil then
                local okS, s = pcall(string.format, "%.0f%%", pctV)
                if okS then txt = s end
            end

            -- Prefer nameplate healthbar geometry for enemies (our row.hp may be meaningless if SetValue/Max failed).
            if txt == nil and self._mode ~= "arena" and IsNameplateUnit(readUnit) then
                local sb = row._hpSB
                if sb == nil then
                    sb = FindPlateHealthStatusBar(readUnit)
                    row._hpSB = sb or false
                elseif sb == false then
                    sb = nil
                end
                if sb then
                    local pct = SafePercentFromStatusBarFill(sb)
                    if pct then txt = pct .. "%" end
                end
            end

            -- Fallback: our own bar geometry (only if everything else failed).
            if txt == nil then
                local pct = SafePercentFromStatusBarFill(row.hp)
                if pct then txt = pct .. "%" end
            end

            -- Last resort: legacy formatter (may fail on secrets; keep pcall).
            if txt == nil then
                local okT, t = pcall(FormatHealthText, cur, maxv, mode)
                if okT then txt = t end
            end
        else
            -- Mode 1 ("Current") and Mode 2 ("Current/Total")
            -- On 12.0+/Midnight, UnitHealth/UnitHealthMax on enemies can be scrubbed/secret and look "wrong" or identical.
            -- Prefer Blizzard's numeric nameplate text when available.
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
                        -- Try to display it right now. If this fails (secret string), fall back below.
                        local okSet = pcall(row.hpText.SetText, row.hpText, s)
                        if okSet then
                            row._lastHpTextAt = now
                            return
                        end
                    end
                end
            end

            -- If numeric text couldn't be shown (often because it's secret), keep it dynamic via fill-geometry %.
            if txt == nil and self._mode ~= "arena" and IsNameplateUnit(readUnit) then
                local sb = row._hpSB
                if sb and sb ~= false then
                    local pct = SafePercentFromStatusBarFill(sb)
                    if pct then txt = pct .. "%" end
                end
            end

            if txt == nil then
                local okT, t = pcall(FormatHealthText, cur, maxv, mode)
                if okT then txt = t end
            end
        end

        -- Don't clear on failure; keep last known text so it doesn't flicker/gap.
        if txt ~= nil then
            row._lastHpTextAt = now
            -- If txt is unusable, SetText will fail and we keep the old value.
            pcall(row.hpText.SetText, row.hpText, txt)
        else
        end
    end
    -- Throttle clip updates (geometry calls are expensive)
    local lastC = row._lastClipAt or 0
    if (now - lastC) >= 5 then
        row._lastClipAt = now
        UpdateNameClipToHPFill(row)
    end
end

function BGE:UpdatePower(row, unit)
    if not GetSetting("bgeShowPower", true) then
        row.power:Hide()
        return
    end

    -- Cache invalidation: nameplate frames get recycled.
    if row._barsUnit ~= unit then
        row._barsUnit = unit
        row._hpSB = nil
        row._pwrSB = nil
    end

    local cur, maxv, r, g, b

    -- Prefer cached nameplate power bar (avoids child scanning every event).
    if self._mode ~= "arena" and IsNameplateUnit(unit) then
        if row._pwrSB == false then
            -- negative cached: don't rescan every event
        elseif row._pwrSB then
            cur, maxv = SafeStatusBarValues(row._pwrSB)
            if cur and maxv and row._pwrR then
                r, g, b = row._pwrR, row._pwrG, row._pwrB
            end
        else
            local sb, rr, gg, bb = FindPlatePowerStatusBar(unit)
            row._pwrSB = sb or false
            row._pwrR, row._pwrG, row._pwrB = rr, gg, bb
            if sb then
                cur, maxv = SafeStatusBarValues(sb)
                r, g, b = rr, gg, bb
            end
        end
    end

    if not cur or not maxv then
        cur, maxv, r, g, b = SafeUnitPower(unit)
    end

    if not cur or not maxv then
        row.power:Hide()
        return
    end

    -- 12.0+/Midnight: cur/maxv may be protected "secret" numbers.
    pcall(row.power.SetMinMaxValues, row.power, 0, maxv)
    pcall(row.power.SetValue, row.power, cur)
    pcall(row.power.SetStatusBarColor, row.power, r, g, b, 0.9)
    row.power:Show()
end

function BGE:GetRowForExternalUnit(unitID)
    if not unitID or not UnitExists(unitID) then return nil end
    if UnitIsFriend("player", unitID) then return nil end

    -- 0) Scoreboard name from GUID (works even when UnitName is restricted)
    do
        local okG, guidRaw = pcall(UnitGUID, unitID)
        if okG and guidRaw then
            local full = ScoreFullNameFromGuid(guidRaw)
            if full and self.rowByFullName then
                local okRow, hit = pcall(function() return self.rowByFullName[full] end)
                if okRow and hit then return hit end
            end
        end
    end

    -- 1) GUID map
    local guid = SafeUnitGUID(unitID)
    if guid and self.rowByGuid then
        local okRow, hit = pcall(function() return self.rowByGuid[guid] end)
        if okRow and hit then return hit end
    end

    -- 2) Full name map
    local full, base = SafeUnitFullName(unitID)
    if full and self.rowByFullName then
        local okRow, hit = pcall(function() return self.rowByFullName[full] end)
        if okRow and hit then return hit end
    end
    if (not full) and base and self.rowByBaseName and self.baseNameCounts and self.baseNameCounts[base] == 1 then
        local okRow, hit = pcall(function() return self.rowByBaseName[base] end)
        if okRow and hit then return hit end
    end

    -- 3) PID maps (strong match first, then loose)
    if self.rowByPID then
        local pid = UnitPIDSeedCompat(unitID)
        if pid and pid > 0 then
            local okRow, hit = pcall(function() return self.rowByPID[pid] end)
            if okRow and hit then return hit end
        end
    end
    if self.rowByPIDLoose then
        local pidL = UnitPIDLooseSeedCompat(unitID)
        if pidL and pidL > 0 then
            local okRow, hit = pcall(function() return self.rowByPIDLoose[pidL] end)
            if okRow and hit then return hit end
        end
    end

    return nil
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
    n = n + 1; units[n] = "focus"
    n = n + 1; units[n] = "mouseover"
    if UnitExists("softenemy") or (UnitGUID and pcall(UnitGUID, "softenemy")) then
        n = n + 1; units[n] = "softenemy"
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
                row._altUnit = u
                row._altSeenAt = GetTime()
                self:UpdateHealth(row, u)
                self:UpdatePower(row, u)
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

    -- Only meaningful once we have scoreboard/roster maps
    if not self.rowByGuid then return end

    local row = self:GetRowForExternalUnit(targetUnit)
    if not row then return end

    row._altUnit = targetUnit
    row._altSeenAt = GetTime()
    self:UpdateHealth(row, targetUnit)
    self:UpdatePower(row, targetUnit)
end

function BGE:HandlePlateAdded(unit)
    if self._mode == "arena" then return end
    if not IsNameplateUnit(unit) then return end
    if not UnitExists(unit) then return end

    if not GetSetting("bgeEnabled", true) then return end
    if not IsInPVPInstance() then return end

    -- Prefer GUID->row match, but GUID is often restricted on enemy nameplates in 12.0.
    -- If GUID is missing/unusable, fall back to the displayed name text on the nameplate frame.
    local row = nil
    local lookedUpBy = "none"

    local guid = SafeUnitGUID(unit)

    -- If GUID is restricted/secret and SafeUnitGUID() returns nil, try scoreboard lookup by raw GUID.
    if not guid and (not row) and self.rowByFullName then
        local okG, guidRaw = pcall(UnitGUID, unit)
        if okG and guidRaw then
            local full = ScoreFullNameFromGuid(guidRaw)
            if full then
                local okRow, hit = pcall(function() return self.rowByFullName[full] end)
                if okRow and hit then row = hit; lookedUpBy = "guidScoreName" end
            end
        end
    end

    if guid and self.rowByGuid then
        local okIdx = true
        okIdx, row = pcall(function() return self.rowByGuid[guid] end)
        if not okIdx then
            BGE:DebugScoreVsNameplate("PLATE_ADDED_SECRET_INDEX", unit, guid)
            row = nil
        elseif row then
            lookedUpBy = "guid"
        end
    end

    if not row then
        local disp, dispBase = GetNameplateDisplayNames(unit)
        -- 1) Try full match first (realm-qualified)
        if disp and self.rowByFullName then
            local okRow, hit = pcall(function() return self.rowByFullName[disp] end)
            if okRow and hit then
                row = hit
                lookedUpBy = "dispFull"
            end
        end
        -- 2) Only if base name is unique, allow base match
        if (not row) and dispBase and self.rowByBaseName and self.baseNameCounts and self.baseNameCounts[dispBase] == 1 then
            local okRow, hit = pcall(function() return self.rowByBaseName[dispBase] end)
            if okRow and hit then
                row = hit
                lookedUpBy = "dispBase"
            end
        end
    end
    -- 3) Fallback: PID match when GUID and display name are unavailable.
    if (not row) and self.rowByPID then
        -- If the unit isn't fully initialized yet (common right after ADDED),
        -- honor/level/faction may be 0/nil, producing a PID that will never match the seeded one.
        local okH, honor = pcall(UnitHonorLevel, unit)
        honor = (okH and type(honor) == "number") and honor or 0
        if honor == 0 and C_Timer and C_Timer.After then
            -- honor can remain 0 indefinitely on hostile units; never allow unbounded retries.
            self._honorZeroRetry = self._honorZeroRetry or {}
            self._honorZeroPending = self._honorZeroPending or {}

            local c = self._honorZeroRetry[unit] or 0
            if c >= 2 then
                self._honorZeroRetry[unit] = nil
                self._honorZeroPending[unit] = nil
            elseif not self._honorZeroPending[unit] then
                self._honorZeroRetry[unit] = c + 1
                self._honorZeroPending[unit] = true
                local u = unit
                C_Timer.After(5, function()
                    local b = _G.RSTATS_BGE
                    if not b then return end
                    b._honorZeroPending[u] = nil
                    if UnitExists(u) then
                        b:HandlePlateAdded(u)
                    end
                end)
            end
        else
            -- Seeded rows are built from scoreboard data which has no level/sex in 12.x,
            -- so PID matching against seeded rows MUST be seed-compatible (level=0, sex=0).
            local pid = UnitPIDSeedCompat(unit)
            if pid and pid > 0 then
                local okRow, hit = pcall(function() return self.rowByPID[pid] end)
                if okRow and hit then
                    row = hit
                    lookedUpBy = "pid"
                end
            end

            -- Mercenary fallback: in merc mode the nameplate race may not match the scoreboard race.
            -- Try a no-race PID, but only if it yields a unique hit (map is unique-only).
            if (not row) and UnitIsMercenary and UnitIsMercenary(unit) and self.rowByPIDNoRace then
                local pidNR = UnitPIDNoRaceSeedCompat(unit)
                if pidNR and pidNR > 0 then
                    local okRowNR, hitNR = pcall(function() return self.rowByPIDNoRace[pidNR] end)
                    if okRowNR and hitNR then
                        row = hitNR
                        lookedUpBy = "pidNoRace"
                    end
                end
            end

            -- Cross-faction/visual race can mismatch even when not flagged as Mercenary.
            -- Still conservative: unique-only map + require honor>0 so we don't bind on early junk.
            if (not row) and self.rowByPIDNoRace and UnitIsPlayer(unit) and (not UnitIsFriend("player", unit)) then
                local okH, honor = pcall(UnitHonorLevel, unit)
                if okH and honor and honor > 0 then
                    local pidNR2 = UnitPIDNoRaceSeedCompat(unit)
                    if pidNR2 and pidNR2 > 0 then
                        local okRowNR2, hitNR2 = pcall(function() return self.rowByPIDNoRace[pidNR2] end)
                        if okRowNR2 and hitNR2 then
                            row = hitNR2
                            lookedUpBy = "pidNoRace2"
                        end
                    end
                end
            end

            -- Loose PID fallback (honor=0 on nameplate units)
            if (not row) and self.rowByPIDLoose then
                local okC, _, _, classID = pcall(UnitClass, unit)
                local facIndex = GetUnitTrueFactionIndex(unit)
                local okR, _, _, raceID = pcall(UnitRace, unit)
                local okL, level = pcall(UnitLevel, unit)
                local okS, sex = pcall(UnitSex, unit)
                if okC and classID then
                    local pidL = UnitPIDLooseSeedCompat(unit)
                    if pidL and pidL > 0 then
                        local okRowL, hitL = pcall(function() return self.rowByPIDLoose[pidL] end)
                        if okRowL and hitL then
                            row = hitL
                            lookedUpBy = "pidLoose"
                        end
                    end
                end
            end
        end
    end

    if GetSetting("bgeDebug", false) then
        local pidStrong = (UnitPID and UnitPID(unit)) or 0
        local pid = UnitPIDSeedCompat(unit)
        DPrint("PIDCHK_"..unit, "PIDCHK unit="..unit.." pid="..tostring(pid).." strong="..tostring(pidStrong).." seeded="..Bool01(self.rowByPID and self.rowByPID[pid] ~= nil))
    end

    if GetSetting("bgeDebug", false) then
        local dispFull = select(1, GetNameplateDisplayNames(unit))
        local pidNow = UnitPIDSeedCompat(unit)
        local pidStrong2 = (UnitPID and UnitPID(unit)) or 0
        DPrint("PLATE_LOOKUP_" .. unit,
            "LOOKUP_PLATE unit=" .. unit ..
            " by=" .. lookedUpBy ..
            " disp=" .. (dispFull or "nil") ..
            " guidKey=" .. (SafeToString(guid) or "<secret>") ..
            " pid=" .. tostring(pidNow) .. " pidS=" .. tostring(pidStrong2) ..
            " hit=" .. Bool01(row ~= nil)
        )
    end

    if not row then
        -- Not seeded yet (scoreboard delay). Keep it simple: ignore until seeded.
        DebugUnitSnapshot("PLATE_ADDED_UNSEEDED", unit)

        -- nameplate units recycle; don't poison retries for a new occupant
        do
            local key = 0
            -- Prefer seed-compatible PID (stable when available)
            if UnitPIDSeedCompat then
                local p = UnitPIDSeedCompat(unit) or 0
                if p and p > 0 then key = p end
            end
            -- fallback to raw pid if seed-compatible isn't ready yet
            if key == 0 and UnitPID then
                local p2 = UnitPID(unit) or 0
                if p2 and p2 > 0 then key = p2 end
            end
            local prev = self._plateAddRetryKey and self._plateAddRetryKey[unit] or nil
            if prev ~= key then
                self._plateAddRetryKey[unit] = key
                if self._plateAddRetry then
                    self._plateAddRetry[unit] = 0
                end
                if self._plateAddRetryPending then
                    self._plateAddRetryPending[unit] = nil
                end
            end
        end

        -- But: nameplate text often appears later and PID isn't unique. Retry a few times.
        if C_Timer and C_Timer.After then
            self._plateAddRetry = self._plateAddRetry or {}
            self._plateAddRetryPending = self._plateAddRetryPending or {}

            local c = self._plateAddRetry[unit] or 0
            if c >= 60 then
                self._plateAddRetry[unit] = nil
                self._plateAddRetryPending[unit] = nil
            elseif not self._plateAddRetryPending[unit] then
                self._plateAddRetry[unit] = c + 1
                self._plateAddRetryPending[unit] = true

                local u = unit
                local expectedKey = self._plateAddRetryKey and self._plateAddRetryKey[unit] or nil
                C_Timer.After(2, function()
                    local b = _G.RSTATS_BGE
                    if not b then return end
                    b._plateAddRetryPending[u] = nil
                    if not UnitExists(u) then return end

                    -- If token recycled, do not keep retrying the wrong occupant.
                    local curKey = b._plateAddRetryKey and b._plateAddRetryKey[u] or nil
                    if expectedKey ~= nil and curKey ~= expectedKey then
                        return
                    end
                    b:HandlePlateAdded(u)
                end)
            end
        end
        return
    end

    self._plateAddRetry[unit] = nil

    -- Nameplate units recycle. Make sure only one row owns this unit token.
    ClearUnitCollision(self, unit, row)

    -- If the row had an old unit mapping, clear it
    if row.unit and self.rowByUnit[row.unit] == row then
        self.rowByUnit[row.unit] = nil
    end

    row.unit = unit
    row._preview = false
    row._outOfRange = false
    row._seeded = nil
    self.rowByUnit[unit] = row

    -- Force bar rescan on new unit token (avoid reusing cached bars from a recycled nameplate)
    if row._barsUnit ~= unit then
        row._barsUnit = nil
        row._hpSB = nil
        row._pwrSB = nil
        row._hpSBAt = nil
        row._pwrSBAt = nil
    end

    -- Make click-to-target correct: bind this roster row to the actual nameplate unit.
    if not InLockdown() then
        row:SetAttribute("unit", unit)
    else
        self.pendingUnitByRow[row] = unit
    end

    self:UpdateIdentity(row, unit)
    self:UpdateHealth(row, unit)
    self:UpdatePower(row, unit)
    ApplyClassAlpha(row, CLASS_ALPHA_ACTIVE)

    DebugUnitSnapshot("PLATE_ADDED", unit)

    -- NAME_PLATE_UNIT_ADDED can arrive before name/class/text is usable.
    -- Only schedule retries if we *still* need them after the first update.
    local needRetry = (not row.name) or (not row.classFile) or (not FontStringHasText(row.hpText))
    if needRetry and C_Timer and C_Timer.After then
        local u = unit
        local r = row
        C_Timer.After(0.5, function()
            if r and r.unit == u and UnitExists(u) then
                DebugUnitSnapshot("PLATE_T+0.5", u)
                if not r.name or not r.classFile or not FontStringHasText(r.hpText) then
                    self:UpdateIdentity(r, u)
                    self:UpdateHealth(r, u)
                    self:UpdatePower(r, u)
                end
            end
        end)
        C_Timer.After(1, function()
            if r and r.unit == u and UnitExists(u) then
                DebugUnitSnapshot("PLATE_T+0.1", u)
                if not r.name then
                    self:UpdateIdentity(r, u)
                end
            end
        end)
    end

    -- Never Show() here; secure rows stay shown forever.
    self:UpdateRowVisibilities()
    self:SyncSelectedRowToTarget()
end

function BGE:HandlePlateRemoved(unit)
    if self._mode == "arena" then return end
    if not IsNameplateUnit(unit) then return end
    local row = self.rowByUnit and self.rowByUnit[unit] or nil
    if not row then return end

    if self._plateAddRetry then self._plateAddRetry[unit] = nil end
    if self._plateAddRetryPending then self._plateAddRetryPending[unit] = nil end

    if self._plateAddRetryKey then
        self._plateAddRetryKey[unit] = nil
    end

    if self._honorZeroRetry then
        self._honorZeroRetry[unit] = nil
    end
    if self._honorZeroPending then
        self._honorZeroPending[unit] = nil
    end

    -- Do NOT wipe. Keep last known identity/bars and just fade until it returns.
    row.unit = nil
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
    -- Don't do any BG nameplate work outside a PvP instance.
    -- (UNIT_* events fire constantly in the open world for creature nameplates.)
    if not GetSetting("bgeEnabled", true) then return end
    local mappedRow = (self._mode ~= "arena") and (self.rowByUnit and self.rowByUnit[unit]) or nil
    if self._mode ~= "arena" then
        if not IsInPVPInstance() then return end
        if not UnitExists(unit) then return end
        if UnitIsFriend("player", unit) then return end
        -- UnitIsPlayer() is unreliable on enemy nameplates after /reload (can return false).
        -- Only hard-skip confirmed friendlies.
    end
    if self._mode == "arena" then
        if not IsArenaUnit(unit) then return end
    else
        if not IsTrackedBGUnit(unit) then return end
    end
    local row
    if self._mode == "arena" then
        row = self:GetRowForUnit(unit)
    else
        row = mappedRow
        if not row then
            -- Late map: try GUID match (covers rare event ordering).
            local guid = SafeUnitGUID(unit)
            if guid and self.rowByGuid then
                local okHas, hit = pcall(function() return self.rowByGuid[guid] end)
                if not okHas then
                    -- Same secret-index crash site; debug and bail.
                    BGE:DebugScoreVsNameplate("UNIT_UPDATE_SECRET_INDEX", unit, guid)
                    return
                end
                DPrint("UNIT_LOOKUP_" .. unit,
                    "LOOKUP_UNIT unit=" .. unit ..
                    " what=" .. tostring(what) ..
                    " guidKey=" .. (SafeToString(guid) or "<secret>") ..
                    " hit=" .. Bool01(hit ~= nil)
                )
                if hit then
                    row = hit
                end
            end

            -- Fallback: fullName match when GUID is blocked/secret (useful for target/focus/ally-target tokens)
            if not row and not IsNameplateUnit(unit) then
                local full = SafeUnitFullName(unit)
                if full and self.rowByName then
                    local okHas2, hit2 = pcall(function() return self.rowByName[full] end)
                    if okHas2 and hit2 then
                        row = hit2
                    end
                end
            end

            -- Fallback: match by displayed name text on the nameplate frame.
            -- This is critical on 12.0 where enemy UnitGUID/UnitName can be restricted.
            if not row then
                local disp, dispBase = GetNameplateDisplayNames(unit)
                if disp and self.rowByFullName then
                    row = self.rowByFullName[disp]
                    if row then
                        DPrint("UNIT_LOOKUPD_" .. unit, "LOOKUP_UNIT_D unit=" .. unit .. " what=" .. tostring(what) .. " by=dispFull hit=1")
                    end
                end
                if (not row) and dispBase and self.rowByBaseName and self.baseNameCounts and self.baseNameCounts[dispBase] == 1 then
                    row = self.rowByBaseName[dispBase]
                    if row then
                        DPrint("UNIT_LOOKUPD_" .. unit, "LOOKUP_UNIT_D unit=" .. unit .. " what=" .. tostring(what) .. " by=dispBase hit=1")
                    end
                end
            end

            if row then
                if IsNameplateUnit(unit) then
                    -- Nameplate units recycle. Make sure only one row owns this unit token.
                    ClearUnitCollision(self, unit, row)

                    -- If the row had an old unit mapping, clear it
                    if row.unit and self.rowByUnit[row.unit] == row then
                        self.rowByUnit[row.unit] = nil
                    end

                    -- Force bar rescan on new unit token
                    if row._barsUnit ~= unit then
                        row._barsUnit = nil
                        row._hpSB = nil
                        row._pwrSB = nil
                        row._hpSBAt = nil
                        row._pwrSBAt = nil
                    end
                    row.unit = unit
                    self.rowByUnit[unit] = row
                    -- Make click-to-target correct only for real nameplate units.
                    if not InLockdown() then
                        row:SetAttribute("unit", unit)
                    else
                        self.pendingUnitByRow[row] = unit
                    end
                else
                    -- Don't bind secure click-to-target to unstable tokens like raid1target/party1target.
                    row._altUnit = unit
                end
            end
        end
    end
    if not row then return end
    if not row.unit and IsNameplateUnit(unit) then
        row.unit = unit
    end

    if what == "NAME" then
        DebugUnitSnapshot("UNIT_NAME_UPDATE", unit)
    end

    -- If UnitName wasn't ready when the plate was added, keep trying.
    -- UNIT_NAME_UPDATE is unreliable for nameplate units, so piggyback on HP/PWR events.
    -- Never compare strings here (row.name may originate from protected sources).
    if (not row.name) and not row._preview then
        local now = GetTime()
        if (not row._lastNameTry) or (now - row._lastNameTry > 1) then
            row._lastNameTry = now
            self:UpdateIdentity(row, unit)
        end
    end

    if what == "NAME" then
        self:UpdateIdentity(row, unit)
        self:UpdateRowVisibilities()
    elseif what == "HP" then
        local now = GetTime()
        local last = row._lastHPAt or 0
        if (not force) and (now - last) < 0.5 then return end
        row._lastHPAt = now
        self:UpdateHealth(row, unit)
    elseif what == "PWR" then
        local now = GetTime()
        local last = row._lastPWRAt or 0
        if (not force) and (now - last) < 0.5 then return end
        row._lastPWRAt = now
        self:UpdatePower(row, unit)
    end
end

function BGE:RefreshVisibility()
    if not self.frame then return end

    if not GetSetting("bgeEnabled", true) then
        -- Don't Hide() container in combat if it contains secure children.
        self.frame:SetAlpha(0)
        self:StopTargetScanner()
        return
    end


    -- Resolve which per-size profile to use while OUTSIDE PvP.
    -- Preview is only supported for one profile at a time.
    if not IsInPVPInstance() then
        local db = GetPlayerDB()
        self._profilePrefix = ResolvePreviewProfilePrefix(db)
    end

    local preview = GetSetting("bgePreview", false)
    if IsInPVPInstance() or preview then
        if not self.frame:IsShown() then
            if InLockdown() then
                self._showDirty = true
            else
                self.frame:Show()
            end
        end
        self.frame:SetAlpha(1)

        -- Keep pulling HP/PWR from target/focus/ally-target tokens while in BG.
        if IsInPVPInstance() and self._mode ~= "arena" then
            self:StartTargetScanner()
        else
            self:StopTargetScanner()
        end

        -- Create only as many secure rows as we are configured to DISPLAY.
        -- Relying on GetNumBattlefieldScores() early/late-join can be too low (e.g. 10 in a 15v15),
        -- which prevents rows 11..15 from ever existing.
        local want = 10
        local rated = false
        local isRatedBG = false
        local isRatedSoloRBG = false

        if (not preview) and IsInPVPInstance() and self._mode ~= "arena" then
            -- Distinguish Rated BG (10v10) vs Rated Solo RBG / Blitz (8v8)
            if C_PvP and C_PvP.IsRatedSoloRBG then
                local okS, s = pcall(C_PvP.IsRatedSoloRBG)
                if okS and s then isRatedSoloRBG = true end
            end

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
            -- want rules (locale-safe via mapID):
            -- rated: 10 (RBG), blitz/solo rbg: 8
            -- not rated:
            --   if bg maxPlayers > 15: 40
            --   if bg maxPlayers == 15: 15   (AB/EotS/DWG are 15s; this also survives locale)
            --   else: 10
            --   else: 15 (create enough rows for 15v15; unused rows stay hidden in 10v10)

            if isRatedSoloRBG then
                want = 8
            elseif isRatedBG then
                want = 10
            else
                local maxPlayers = nil

                -- Primary source of truth: current instance maxPlayers (no mapID/index guessing).
                -- GetInstanceInfo() returns: 1 name, 2 instanceType, 3 difficultyID, 4 difficultyName, 5 maxPlayers, 6 dynamicDifficulty,
                -- 7 isDynamic, 8 instanceMapID, ...
                local okGI, instName, instType, _, _, instMaxPlayers, _, instMapID = pcall(_G.GetInstanceInfo)
                if okGI and instType == "pvp" and type(instMaxPlayers) == "number" and instMaxPlayers > 0 then
                    maxPlayers = instMaxPlayers

                    -- 15v15 map-type override:
                    -- Some 15v15 BGs can report 10 briefly/incorrectly on zone-in; force 15 for these maps.
                    -- AB=461, EotS=482, DWG=935 (InstanceMapID from GetInstanceInfo()).
                    if maxPlayers == 10 and (instName == "Arathi Basin" or instName == "Eye of the Storm" or instName == "Deepwind Gorge") then
                        maxPlayers = 15
                    end

                    -- Epic BG exceptions: these are 35-per-faction (not 40).
                    -- Ashran / Isle of Conquest / Battle for Wintergrasp were set to 35 in Blizzard patch notes.
                    -- (GetInstanceInfo can still report 40, so clamp it here.)
                    if maxPlayers == 40 then
                        if instName == "Ashran" then
                            maxPlayers = 35
                        end
                    end

                    -- Success: clear any pending retry state.
                    self._mpRetryCount = nil
                    self._mpRetryPending = nil
                elseif okGI and instType == "pvp" and (not preview) and self._mode ~= "arena" then
                    -- Zone-in timing: maxPlayers can be unavailable briefly. Retry 1s up to 3 times.
                    self._mpRetryCount = (self._mpRetryCount or 0)
                    if (self._mpRetryCount < 10) and (not self._mpRetryPending) and _G.C_Timer and _G.C_Timer.After then
                        self._mpRetryPending = true
                        self._mpRetryCount = self._mpRetryCount + 1
                        _G.C_Timer.After(1, function()
                            if not self then return end
                            self._mpRetryPending = nil
                            -- Only retry while still in a PvP instance.
                            if IsInPVPInstance() then
                                self:RefreshVisibility()
                            else
                                self._mpRetryCount = nil
                            end
                        end)
                    end
                    -- Don't lock in fallback sizing while retries are in flight.
                    if not maxPlayers and self._mpRetryPending then
                        return
                    end
                end

                -- Fallback: BattlegroundInfo list (can fail if uiMapID is a child map).
                local mapID = nil
                if not maxPlayers and C_Map and C_Map.GetBestMapForUnit then
                    local okM, mid = pcall(C_Map.GetBestMapForUnit, "player")
                    if okM then mapID = mid end
                end

                -- BattlegroundInfo includes maxPlayers and optional mapID; match by mapID.
                if not maxPlayers and mapID and C_PvP and C_PvP.GetNumBattlegroundTypes and C_PvP.GetBattlegroundInfo then
                    local okN, tN = pcall(C_PvP.GetNumBattlegroundTypes)
                    if okN and type(tN) == "number" then
                        for idx = 1, tN do
                            local okI, bi = pcall(C_PvP.GetBattlegroundInfo, idx)
                            if okI and bi and bi.mapID == mapID and type(bi.maxPlayers) == "number" then
                                maxPlayers = bi.maxPlayers
                                break
                            end
                        end
                    end
                end

                -- Prefer resolved maxPlayers (handles 10v10 variants on "15v15 maps").
                if maxPlayers and maxPlayers > 15 then
                    if maxPlayers == 35 then
                        want = 35
                    else
                        want = 40
                    end
                elseif maxPlayers and maxPlayers == 15 then
                    want = 15
                elseif maxPlayers and maxPlayers == 10 then
                    want = 10
                else
                    -- If we can't confidently resolve maxPlayers yet (mapID timing / API quirks),
                    -- default to 10 for normal BGs.
                    want = 10
                end
            end -- rated
        end -- preview/arena/bg
        -- Select the per-size layout profile for this match.
        -- This drives the columns/rows/width/height/gaps used by ApplyAnchors/ApplyRowLayout.
        -- Only pick a live-match profile inside PvP; preview uses ResolvePreviewProfilePrefix() at the top.
        if (not preview) and IsInPVPInstance() and self._mode ~= "arena" then
            if isRatedSoloRBG and want == 8 then
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

        -- Use want as the expected enemy team size target for seeding retries.
        if not preview and self._mode ~= "arena" and IsInPVPInstance() then
            self._expectedBGTeamSize = nil
            self._expectedBGTeamSizeGuess = want
            self._enteredBGAt = self._enteredBGAt or GetTime()
        end

        self:UpdateFrameTeamTint()
        -- Keep scoreboard cache warm while in a PvP instance.
        if IsInPVPInstance() then
            -- Ensure the Blizzard PvP scoreboard addon is loaded so GetNumBattlefieldScores/GetBattlefieldScore
            -- (and RequestBattlefieldScoreData) exist even before the user opens the scoreboard.
            -- Without this, seeding won't happen until the scoreboard UI is shown.
            if (not _G.GetNumBattlefieldScores) or (not _G.GetBattlefieldScore) then
                if _G.UIParentLoadAddOn then
                    pcall(_G.UIParentLoadAddOn, "Blizzard_PVPMatch")
                elseif _G.LoadAddOn then
                    pcall(_G.LoadAddOn, "Blizzard_PVPMatch")
                end
            end

            self:RebuildScoreCache()
            if _G.RequestBattlefieldScoreData then
                pcall(_G.RequestBattlefieldScoreData)
            end
            -- As soon as we have a scoreboard, seed the initial class rows (BG start)
            self:SeedRowsFromScoreboard()

            -- Keepalive: keep requesting/refreshing score data while in a BG.
            self:StartScoreWarmup()
        end
        self:EnsurePreviewRows()

        -- If we /reload while already in a BG, existing plates may not re-fire ADDED.
        -- Do a quick scan to seed rows (same idea as the original ENP script).
        if IsInPVPInstance() and self._mode ~= "arena" then
            for i = 1, self.maxPlates do
                local u = "nameplate" .. i
                if UnitExists(u) then
                    self:HandlePlateAdded(u)
                end
            end
        end

        self:UpdateRowVisibilities()
    else
        -- Leaving PvP: hard clear
        self:StopTargetScanner()
        self:StopScoreWarmup()
        self:ClearPreviewRows()
        for _, row in ipairs(self.rows) do
            self:ReleaseRow(row)
        end
        self._seededThisBG = false
        self._seedCount = 0
        wipe(self.scoreClassList)
        wipe(self.roster)
        wipe(self.rowByGuid)
        wipe(self.rowByUnit)
        wipe(self.rowByName)
        wipe(self.nameCounts)
        wipe(self.pendingUnitByGuid)
        wipe(self.pendingUnitByRow)
        self._expectedBGTeamSize = nil
        self._expectedBGTeamSizeGuess = nil
        self._enteredBGAt = nil
        self._seedStartRetries = nil
        self._seedRetryPending = nil
        self.frame:SetAlpha(0)
        if not InLockdown() then
            self.frame:Hide()
        end
    end
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
        -- Outside PvP, Settings can enable preview after login. Bootstrap the frame here.
        if (IsInPVPInstance() or GetSetting("bgePreview", false)) and CreateMainFrame then
            CreateMainFrame()
        end
        return
    end

    -- If preview gets enabled AFTER login (outside PvP), the frame won't exist yet.
    -- Bootstrap it here so Settings -> Preview immediately shows the frame.
    if not self.frame then
        local preview = GetSetting("bgePreview", false)
        if (IsInPVPInstance() or preview) and CreateMainFrame then
            CreateMainFrame()
        end
        return
    end

    -- Achievements icon visibility: when toggled (or when the Achievements API becomes available),
    -- clear cached icon data so rows re-evaluate and redraw immediately.
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

    -- Allow dragging by the chat-style anchor tab as well (rows/buttons can steal mouse input).
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

    -- Light polling loop: fixes "Enemy forever"/blank forever by retrying until UnitName becomes available.
    f._bgeRetryAccum = 0
    f._bgeBarsAccum = 0
    f:SetScript("OnUpdate", function(_, elapsed)
        if not _G.RSTATS_BGE then return end
        -- Critical: never do identity retry polling in combat; it's too expensive in big fights.
        if InLockdown() then return end
        f._bgeRetryAccum = (f._bgeRetryAccum or 0) + (elapsed or 0)
        if f._bgeRetryAccum < 10 then return end
        f._bgeRetryAccum = 0
        _G.RSTATS_BGE:RetryMissingIdentities()
    end)

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

evt:RegisterEvent("UPDATE_BATTLEFIELD_SCORE")
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
        -- Apply deferred GUID->unit bindings after combat (secure attribute).
        if _G.RSTATS_BGE and _G.RSTATS_BGE.pendingUnitByGuid then
            for guid, unit in pairs(_G.RSTATS_BGE.pendingUnitByGuid) do
                local row = _G.RSTATS_BGE.rowByGuid and _G.RSTATS_BGE.rowByGuid[guid] or nil
                if row and unit and UnitExists(unit) then
                    row:SetAttribute("unit", unit)
                end
                _G.RSTATS_BGE.pendingUnitByGuid[guid] = nil
            end
        end
		if _G.RSTATS_BGE and _G.RSTATS_BGE.pendingUnitByRow then
			for row, unit in pairs(_G.RSTATS_BGE.pendingUnitByRow) do
				if row and unit and UnitExists(unit) then
					row:SetAttribute("unit", unit)
				end
				_G.RSTATS_BGE.pendingUnitByRow[row] = nil
			end
		end
        -- Apply deferred macrotext updates after combat (secure attribute).
        if _G.RSTATS_BGE and _G.RSTATS_BGE.pendingMacroByRow then
            for row, macro in pairs(_G.RSTATS_BGE.pendingMacroByRow) do
                if row and macro then
                    row:SetAttribute("macrotext", macro)
                end
                _G.RSTATS_BGE.pendingMacroByRow[row] = nil
            end
        end
        return
    end

    if event == "UPDATE_BATTLEFIELD_SCORE" then
        BGE:ScheduleSeedFromScoreboard()
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
        -- Event can fire before the plate is fully usable; do a 0-delay retry as well.
        if C_Timer and C_Timer.After then
            local unit = arg1
            C_Timer.After(0, function()
                BGE:HandlePlateAdded(unit)
            end)
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

    if event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
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