-- Reactive Markets (PropaineX)
-- Selling at a buyer lowers that buyer's price a little and raises every rival buyer's price a little.
-- Each buyer keeps a hidden factor ("hunger") per fill type; price = game price x factor.
-- Factors drift back to 1.00 every in-game hour. Stage 1: single player / server only.

ReactiveMarkets = {}
local RM = ReactiveMarkets

RM.MOD_NAME = g_currentModName
RM.MOD_DIR = g_currentModDirectory
RM.SAVE_FILE = "reactiveMarkets.xml"
RM.IGNORED_MODS = { FS25_PalletDepot = true }   -- placeables from these mods are not markets
RM.LOG_PREFIX = "[ReactiveMarkets] "

RM.settings = {
    minHunger = 0.85,
    maxHunger = 1.15,
    sellerStep = 0.04,
    rivalStep = 0.02,
    batchLiters = 30000,
    allowanceLiters = 200000,
    recoveryDays = 6,
    debug = false,
    batchByFillType = {},   -- [fillTypeIndex] = liters
    disabled = {},          -- [fillTypeIndex] = true
}

RM.hunger = {}          -- [station] = { [fillTypeIndex] = factor }
RM.volume = {}          -- [station] = { [fillTypeIndex] = liters taken lately (drains like hunger) }
RM.history = {}         -- [station] = { [fillTypeIndex] = {factor per in-game hour, oldest first} } (ESC page graphs)
RM.HISTORY_HOURS = 144  -- 6 days
RM.loaded = false
RM.saleLog = {}         -- debug: [station] = { [fillTypeIndex] = {liters, before, lastTime} }
RM.unloads = {}         -- server: [station] = { [fillTypeIndex] = g_time of the last chunk past the allowance }
RM.UNLOAD_GAP = 3000    -- ms without a new chunk = the load is finished

-- Random climb (user 2026-11-19): once per finished load that went past the free allowance, every rival buyer
-- of that crop except the one paying the most right now gets an extra random +0.5 % to +1.5 % (never past the
-- limit), so the buyers below the top climb in a random order.
RM.RANDOM_EXTRA_MIN = 0.005
RM.RANDOM_EXTRA_MAX = 0.015

function RM.applyRandomClimb(station, ft)
    local s = RM.settings
    local top, topPrice = nil, -1
    local rivals = {}
    for _, other in ipairs(RM.getStations()) do
        if other ~= station and other.acceptedFillTypes[ft] then
            local price = other:getEffectiveFillTypePrice(ft) or 0
            if price > 0 then
                table.insert(rivals, other)
                if price > topPrice then
                    top, topPrice = other, price
                end
            end
        end
    end
    local n = 0
    for _, other in ipairs(rivals) do
        if other ~= top then
            local extra = RM.RANDOM_EXTRA_MIN + math.random() * (RM.RANDOM_EXTRA_MAX - RM.RANDOM_EXTRA_MIN)
            RM.setHunger(other, ft, math.min(s.maxHunger, RM.getHunger(other, ft) + extra))
            n = n + 1
        end
    end
    if s.debug then
        print(RM.LOG_PREFIX .. string.format("random climb after a load at '%s': %d rivals got +0.5..1.5%%, top buyer '%s' left out",
            RM.getStationName(station), n, top ~= nil and RM.getStationName(top) or "-"))
    end
end

function RM.finishUnloads(force)
    for station, t in pairs(RM.unloads) do
        for ft, last in pairs(t) do
            if force or g_time - last > RM.UNLOAD_GAP then
                t[ft] = nil
                RM.applyRandomClimb(station, ft)
            end
        end
        if next(t) == nil then
            RM.unloads[station] = nil
        end
    end
end

local function log(fmt, ...)
    print(RM.LOG_PREFIX .. string.format(fmt, ...))
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------

function RM.readSettingsFile(path)
    if path == nil or not fileExists(path) then
        return false
    end
    local xml = loadXMLFile("ReactiveMarketsSettings", path)
    if xml == nil or xml == 0 then
        return false
    end
    local s = RM.settings
    s.minHunger = getXMLFloat(xml, "reactiveMarkets.limits#min") or s.minHunger
    s.maxHunger = getXMLFloat(xml, "reactiveMarkets.limits#max") or s.maxHunger
    s.sellerStep = getXMLFloat(xml, "reactiveMarkets.steps#seller") or s.sellerStep
    s.rivalStep = getXMLFloat(xml, "reactiveMarkets.steps#rival") or s.rivalStep
    s.batchLiters = getXMLFloat(xml, "reactiveMarkets.steps#batchLiters") or s.batchLiters
    s.allowanceLiters = getXMLFloat(xml, "reactiveMarkets.allowance#liters") or s.allowanceLiters
    s.recoveryDays = getXMLFloat(xml, "reactiveMarkets.recovery#days") or s.recoveryDays
    local dbg = getXMLBool(xml, "reactiveMarkets.debug#enabled")
    if dbg ~= nil then s.debug = dbg end

    s.batchByFillType = {}
    s.disabled = {}
    local i = 0
    while true do
        local key = string.format("reactiveMarkets.fillTypes.fillType(%d)", i)
        if not hasXMLProperty(xml, key) then
            break
        end
        local name = getXMLString(xml, key .. "#name")
        local ft = name ~= nil and g_fillTypeManager:getFillTypeIndexByName(name) or nil
        if ft ~= nil then
            local batch = getXMLFloat(xml, key .. "#batchLiters")
            if batch ~= nil and batch > 0 then
                s.batchByFillType[ft] = batch
            end
            if getXMLBool(xml, key .. "#enabled") == false then
                s.disabled[ft] = true
            end
        elseif name ~= nil then
            log("settings: unknown fill type '%s' ignored", name)
        end
        i = i + 1
    end
    delete(xml)

    -- sanity
    s.minHunger = clamp(s.minHunger, 0.1, 1.0)
    s.maxHunger = clamp(s.maxHunger, 1.0, 3.0)
    s.sellerStep = clamp(s.sellerStep, 0, 0.99)
    s.rivalStep = clamp(s.rivalStep, 0, 0.99)
    s.batchLiters = math.max(s.batchLiters, 1)
    s.allowanceLiters = math.max(s.allowanceLiters, 0)
    s.recoveryDays = math.max(s.recoveryDays, 0.1)
    return true
end

function RM.loadSettings()
    local defaultPath = RM.MOD_DIR .. "settings.xml"
    local userPath = nil
    if g_modSettingsDirectory ~= nil then
        userPath = g_modSettingsDirectory .. RM.MOD_NAME .. ".xml"
        if not fileExists(userPath) then
            -- plain calls (ModHub: no protected calls); both are engine functions in FS25
            if createFolder ~= nil then
                createFolder(g_modSettingsDirectory)
            end
            if copyFile ~= nil then
                copyFile(defaultPath, userPath, false)
            end
        end
    end
    if RM.readSettingsFile(userPath) then
        log("settings loaded from %s", userPath)
    elseif RM.readSettingsFile(defaultPath) then
        log("settings loaded from mod defaults")
    end
    local s = RM.settings
    log("limits %.2f-%.2f, steps seller %.2f rival %.2f per %d l, allowance %d l, recovery %.1f days, debug %s",
        s.minHunger, s.maxHunger, s.sellerStep, s.rivalStep, s.batchLiters, s.allowanceLiters, s.recoveryDays, tostring(s.debug))
end

-------------------------------------------------------------------------------
-- Stations
-------------------------------------------------------------------------------

function RM.isEligibleStation(station)
    if type(station) ~= "table" or station.acceptedFillTypes == nil or station.getEffectiveFillTypePrice == nil then
        return false
    end
    -- the Logistics Hub depots (FS25_PalletDepot) only store and spawn pallets: never a buyer, never a rival
    -- (user, 2026-11-19)
    local p = station.owningPlaceable
    if p ~= nil and RM.IGNORED_MODS[p.customEnvironment or ""] then
        return false
    end
    -- every other place that buys counts, whoever owns it (map, player, production)
    return true
end

RM.known = {}          -- every station seen in a price or sale call: [station] = true

local function addFrom(raw, list, seen)
    if type(raw) ~= "table" then
        return
    end
    for k, v in pairs(raw) do
        local station = (type(v) == "table" and v.acceptedFillTypes ~= nil) and v or k
        if not seen[station] and RM.isEligibleStation(station) then
            seen[station] = true
            table.insert(list, station)
        end
    end
end

function RM.getStations()
    local list, seen = {}, {}
    local mission = g_currentMission
    if mission == nil then
        return list
    end
    local em = mission.economyManager
    if em ~= nil then
        if em.getSellingStations ~= nil then
            addFrom(em:getSellingStations(), list, seen)
        end
        addFrom(em.sellingStations, list, seen)
    end
    local ss = mission.storageSystem
    if ss ~= nil then
        if ss.getSellingStations ~= nil then
            addFrom(ss:getSellingStations(), list, seen)
        end
        if ss.getUnloadingStations ~= nil then
            addFrom(ss:getUnloadingStations(), list, seen)
        end
        addFrom(ss.unloadingStations, list, seen)
    end
    addFrom(RM.known, list, seen)
    return list
end

function RM.getStationName(station)
    if station.getName ~= nil then
        local name = station:getName()
        if name ~= nil then
            return tostring(name)
        end
    end
    return "?"
end

-- stable key for saving: owning placeable's uniqueId (+ index if one placeable has several stations)
function RM.buildStationKeys()
    local keys, byKey = {}, {}
    for _, station in ipairs(RM.getStations()) do
        local p = station.owningPlaceable
        local base = nil
        if p ~= nil and p.getUniqueId ~= nil then
            base = p:getUniqueId()
        end
        if base == nil then
            base = "name_" .. RM.getStationName(station)
        end
        local key, n = base, 1
        while byKey[key] ~= nil do
            n = n + 1
            key = base .. "#" .. n
        end
        keys[station] = key
        byKey[key] = station
    end
    return keys, byKey
end

-------------------------------------------------------------------------------
-- Hunger
-------------------------------------------------------------------------------

function RM.getHunger(station, ft)
    local t = RM.hunger[station]
    return (t ~= nil and t[ft]) or 1.0
end

-- snap: only the hourly recovery snaps values close to 1.00 back to exactly 1.00
-- (a sale arrives in many tiny chunks; snapping there would erase every chunk)
function RM.setHunger(station, ft, value, snap)
    local s = RM.settings
    value = clamp(value, s.minHunger, s.maxHunger)
    RM.markDirty(station, ft)
    local t = RM.hunger[station]
    if snap and math.abs(value - 1.0) < 0.0005 then
        if t ~= nil then
            t[ft] = nil
        end
        return
    end
    if t == nil then
        t = {}
        RM.hunger[station] = t
    end
    t[ft] = value
end

-------------------------------------------------------------------------------
-- Multiplayer sync (server -> clients), see ReactiveMarketsSyncEvent.lua
-------------------------------------------------------------------------------

RM.dirty = {}            -- server: [station] = { [fillTypeIndex] = true } changed since the last send
RM.syncTimer = 0
RM.SYNC_INTERVAL = 1000  -- ms: changes are collected and sent at most once a second

function RM.isServer()
    return g_currentMission ~= nil and g_currentMission:getIsServer()
end

function RM.markDirty(station, ft)
    if RM.isServer() then
        local d = RM.dirty[station]
        if d == nil then
            d = {}
            RM.dirty[station] = d
        end
        d[ft] = true
    end
end

local function canSend(station)
    return NetworkUtil ~= nil and NetworkUtil.getObjectId(station) ~= nil
end

function RM.collectEntries(source)
    local entries = {}
    for station, fts in pairs(source) do
        if canSend(station) then
            for ft, _ in pairs(fts) do
                local vt = RM.volume[station]
                table.insert(entries, { station = station, fillType = ft, factor = RM.getHunger(station, ft),
                    volume = vt ~= nil and vt[ft] or 0 })
            end
        end
    end
    return entries
end

-- server: send what changed to every client
function RM.sendDirty()
    if next(RM.dirty) == nil then
        return
    end
    local entries = RM.collectEntries(RM.dirty)
    RM.dirty = {}
    if #entries > 0 and g_server ~= nil then
        g_server:broadcastEvent(ReactiveMarketsSyncEvent.new(entries, false))
    end
end

-- server: a player joined, send the whole table
function RM.sendInitialClientState(mission, connection, user, farm)
    if connection ~= nil and RM.isServer() then
        local all = {}
        for _, src in ipairs({ RM.hunger, RM.volume }) do
            for station, t in pairs(src) do
                for ft, _ in pairs(t) do
                    all[station] = all[station] or {}
                    all[station][ft] = true
                end
            end
        end
        connection:sendEvent(ReactiveMarketsSyncEvent.new(RM.collectEntries(all), true))
    end
end

-- client: store what the server sent (no limits or snapping: the server already did that)
function RM.applySync(entries, full)
    if full then
        RM.hunger = {}
        RM.volume = {}
    end
    for _, e in ipairs(entries) do
        local vt = RM.volume[e.station]
        if (e.volume or 0) >= 1 then
            if vt == nil then
                vt = {}
                RM.volume[e.station] = vt
            end
            vt[e.fillType] = e.volume
        elseif vt ~= nil then
            vt[e.fillType] = nil
            if next(vt) == nil then
                RM.volume[e.station] = nil
            end
        end
        local t = RM.hunger[e.station]
        if math.abs(e.factor - 1.0) < 0.0001 then
            if t ~= nil then
                t[e.fillType] = nil
                if next(t) == nil then
                    RM.hunger[e.station] = nil
                end
            end
        else
            if t == nil then
                t = {}
                RM.hunger[e.station] = t
            end
            t[e.fillType] = e.factor
        end
    end
end

-------------------------------------------------------------------------------
-- History for the ESC page graphs (every machine samples its own factors once per in-game hour;
-- not saved, so the graphs start flat after a load or a join)
-------------------------------------------------------------------------------

function RM.sampleHistory()
    local keep = {}
    for station, t in pairs(RM.hunger) do
        for ft, _ in pairs(t) do
            keep[station] = keep[station] or {}
            keep[station][ft] = true
        end
    end
    for station, t in pairs(RM.history) do
        for ft, _ in pairs(t) do
            keep[station] = keep[station] or {}
            keep[station][ft] = true
        end
    end
    for station, fts in pairs(keep) do
        for ft, _ in pairs(fts) do
            local ht = RM.history[station]
            if ht == nil then
                ht = {}
                RM.history[station] = ht
            end
            local list = ht[ft] or {}
            ht[ft] = list
            table.insert(list, RM.getHunger(station, ft))
            while #list > RM.HISTORY_HOURS do
                table.remove(list, 1)
            end
            -- a fully flat history at 1.00 is dropped
            local flat = true
            for _, v in ipairs(list) do
                if math.abs(v - 1) > 0.0005 then
                    flat = false
                    break
                end
            end
            if flat then
                ht[ft] = nil
                if next(ht) == nil then
                    RM.history[station] = nil
                end
            end
        end
    end
end

-- HISTORY_HOURS + 1 values, oldest first, padded with 1.00 at the front, the live factor last
function RM.getHistory(station, ft)
    local out = {}
    local ht = RM.history[station]
    local list = ht ~= nil and ht[ft] or {}
    for _ = 1, RM.HISTORY_HOURS - #list do
        table.insert(out, 1.0)
    end
    for _, v in ipairs(list) do
        table.insert(out, v)
    end
    table.insert(out, RM.getHunger(station, ft))
    return out
end

function RM.isFillTypeEnabled(ft)
    return ft ~= nil and not RM.settings.disabled[ft]
end

function RM.getBatch(ft)
    return RM.settings.batchByFillType[ft] or RM.settings.batchLiters
end

-- Each batch closes a fixed share of the remaining gap to the limit, so steps shrink near the
-- limit and the result is the same whether a load arrives in one piece or many small pieces.
function RM.registerSale(station, ft, liters)
    if liters <= 0 or not RM.isFillTypeEnabled(ft) or not RM.isEligibleStation(station) then
        return
    end
    local s = RM.settings
    -- allowance: the first allowanceLiters a buyer takes (lately) of a crop move nothing
    local vt = RM.volume[station]
    if vt == nil then
        vt = {}
        RM.volume[station] = vt
    end
    local taken = vt[ft] or 0
    local free = math.max(0, s.allowanceLiters - taken)
    vt[ft] = taken + liters
    RM.markDirty(station, ft)
    local penalized = math.max(0, liters - free)

    local before = RM.getHunger(station, ft)
    if s.debug then
        local byFt = RM.saleLog[station]
        if byFt == nil then
            byFt = {}
            RM.saleLog[station] = byFt
        end
        local e = byFt[ft]
        if e == nil then
            e = { liters = 0, penalized = 0, before = before }
            byFt[ft] = e
        end
        e.liters = e.liters + liters
        e.penalized = e.penalized + penalized
        e.lastTime = g_time
    end
    if penalized <= 0 then
        return
    end

    -- remember this unload; when it is finished (no new chunk for UNLOAD_GAP ms) the rivals get their random extra
    local ut = RM.unloads[station]
    if ut == nil then
        ut = {}
        RM.unloads[station] = ut
    end
    ut[ft] = g_time

    local batches = penalized / RM.getBatch(ft)
    local fSeller = 1 - (1 - s.sellerStep) ^ batches
    local fRival = 1 - (1 - s.rivalStep) ^ batches

    RM.setHunger(station, ft, before + (s.minHunger - before) * fSeller)

    for _, other in ipairs(RM.getStations()) do
        if other ~= station and other.acceptedFillTypes[ft] then
            local h = RM.getHunger(other, ft)
            RM.setHunger(other, ft, h + (s.maxHunger - h) * fRival)
        end
    end
end

function RM.recoverHour()
    local hours = RM.settings.recoveryDays * 24
    local keep = 0.05 ^ (1 / hours)   -- ~95% back to normal after recoveryDays
    for station, t in pairs(RM.hunger) do
        for ft, h in pairs(t) do
            RM.setHunger(station, ft, 1.0 + (h - 1.0) * keep, true)
        end
        if next(t) == nil then
            RM.hunger[station] = nil
        end
    end
    for station, t in pairs(RM.volume) do
        for ft, v in pairs(t) do
            v = v * keep
            t[ft] = v >= 1 and v or nil
            RM.markDirty(station, ft)
        end
        if next(t) == nil then
            RM.volume[station] = nil
        end
    end
end

-- debug: print one summary line per finished unload (no chunk for 3 s)
function RM.flushSaleLog(force)
    for station, byFt in pairs(RM.saleLog) do
        for ft, e in pairs(byFt) do
            if force or g_time - (e.lastTime or 0) > 3000 then
                local rivals, sum = 0, 0
                for _, other in ipairs(RM.getStations()) do
                    if other ~= station and other.acceptedFillTypes[ft] then
                        rivals = rivals + 1
                        sum = sum + RM.getHunger(other, ft)
                    end
                end
                local vt = RM.volume[station]
                log("sold %d l %s at '%s' (%d l over the allowance, %d l taken lately): factor %.3f -> %.3f, %d rivals avg %.3f",
                    e.liters, g_fillTypeManager:getFillTypeNameByIndex(ft) or tostring(ft), RM.getStationName(station),
                    e.penalized or 0, vt ~= nil and vt[ft] or 0,
                    e.before, RM.getHunger(station, ft), rivals, rivals > 0 and sum / rivals or 1)
                byFt[ft] = nil
            end
        end
        if next(byFt) == nil then
            RM.saleLog[station] = nil
        end
    end
end

-------------------------------------------------------------------------------
-- Save / load (own file in the savegame folder)
-------------------------------------------------------------------------------

function RM.getSavePath(dir)
    dir = dir or (g_currentMission ~= nil and g_currentMission.missionInfo ~= nil and g_currentMission.missionInfo.savegameDirectory)
    if dir == nil then
        return nil
    end
    return dir .. "/" .. RM.SAVE_FILE
end

function RM.save(dir)
    local path = RM.getSavePath(dir)
    if path == nil then
        return
    end
    local keys = RM.buildStationKeys()
    local xml = createXMLFile("ReactiveMarketsSave", path, "reactiveMarkets")
    if xml == nil or xml == 0 then
        return
    end
    -- one entry per station + fill type that has a factor or recent volume
    local pairsToSave = {}
    for _, src in ipairs({ RM.hunger, RM.volume }) do
        for station, t in pairs(src) do
            for ft, _ in pairs(t) do
                pairsToSave[station] = pairsToSave[station] or {}
                pairsToSave[station][ft] = true
            end
        end
    end
    local i = 0
    for station, fts in pairs(pairsToSave) do
        local sk = keys[station]
        if sk ~= nil then
            for ft, _ in pairs(fts) do
                local key = string.format("reactiveMarkets.entry(%d)", i)
                local vt = RM.volume[station]
                setXMLString(xml, key .. "#station", sk)
                setXMLString(xml, key .. "#fillType", g_fillTypeManager:getFillTypeNameByIndex(ft) or "")
                setXMLFloat(xml, key .. "#factor", RM.getHunger(station, ft))
                setXMLFloat(xml, key .. "#volume", vt ~= nil and vt[ft] or 0)
                i = i + 1
            end
        end
    end
    saveXMLFile(xml)
    delete(xml)
    if RM.settings.debug then
        log("saved %d factors", i)
    end
end

function RM.load()
    RM.loaded = true
    log("found %d buyers at start (more are added as the game asks their prices)", #RM.getStations())
    local path = RM.getSavePath()
    if path == nil or not fileExists(path) then
        return
    end
    local _, byKey = RM.buildStationKeys()
    local xml = loadXMLFile("ReactiveMarketsSave", path)
    if xml == nil or xml == 0 then
        return
    end
    local i, n, missing = 0, 0, 0
    while true do
        local key = string.format("reactiveMarkets.entry(%d)", i)
        if not hasXMLProperty(xml, key) then
            break
        end
        local station = byKey[getXMLString(xml, key .. "#station") or ""]
        local ft = g_fillTypeManager:getFillTypeIndexByName(getXMLString(xml, key .. "#fillType") or "")
        local h = getXMLFloat(xml, key .. "#factor")
        if station ~= nil and ft ~= nil and h ~= nil and station.acceptedFillTypes[ft] then
            RM.setHunger(station, ft, h, true)
            local v = getXMLFloat(xml, key .. "#volume")
            if v ~= nil and v >= 1 then
                RM.volume[station] = RM.volume[station] or {}
                RM.volume[station][ft] = v
            end
            n = n + 1
        else
            missing = missing + 1
        end
        i = i + 1
    end
    delete(xml)
    log("loaded %d factors (%d skipped)", n, missing)
end

-------------------------------------------------------------------------------
-- Hooks
-------------------------------------------------------------------------------

function RM.getEffectiveFillTypePrice(station, superFunc, fillTypeIndex, ...)
    RM.known[station] = true
    local price = superFunc(station, fillTypeIndex, ...)
    if type(price) == "number" and price > 0 then
        local t = RM.hunger[station]
        if t ~= nil and t[fillTypeIndex] ~= nil then
            price = price * t[fillTypeIndex]
        end
    end
    return price
end

-- the sale is paid at the current price first, then the market reacts
function RM.sellFillType(station, superFunc, farmId, fillDelta, fillTypeIndex, ...)
    RM.known[station] = true
    local result = { superFunc(station, farmId, fillDelta, fillTypeIndex, ...) }
    if g_currentMission ~= nil and g_currentMission:getIsServer() and type(fillDelta) == "number" then
        RM.registerSale(station, fillTypeIndex, math.abs(fillDelta))
    end
    return unpack(result)
end

function RM.onSaveCareer(missionInfo)
    if g_currentMission ~= nil and g_currentMission:getIsServer() and missionInfo ~= nil then
        RM.save(missionInfo.savegameDirectory)
    end
end

if SellingStation ~= nil then
    SellingStation.getEffectiveFillTypePrice = Utils.overwrittenFunction(SellingStation.getEffectiveFillTypePrice, RM.getEffectiveFillTypePrice)
    SellingStation.sellFillType = Utils.overwrittenFunction(SellingStation.sellFillType, RM.sellFillType)
else
    log("ERROR: SellingStation not found, mod inactive")
end
FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, RM.onSaveCareer)
if FSBaseMission ~= nil and FSBaseMission.sendInitialClientState ~= nil then
    FSBaseMission.sendInitialClientState = Utils.appendedFunction(FSBaseMission.sendInitialClientState, RM.sendInitialClientState)
else
    log("WARNING: FSBaseMission.sendInitialClientState not found, joining players see normal prices until the next change")
end
-- ESC page: added once the mission has loaded, on every machine with a screen (not on a dedicated server)
if Mission00 ~= nil and Mission00.loadMission00Finished ~= nil then
    Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, function()
        if g_dedicatedServer == nil and ReactiveMarketsFrame ~= nil then
            ReactiveMarketsFrame.register()
        end
    end)
end

-------------------------------------------------------------------------------
-- Mod event listener
-------------------------------------------------------------------------------

function RM:loadMap(name)
    RM.loadSettings()
    g_messageCenter:subscribe(MessageType.HOUR_CHANGED, RM.onHourChanged, RM)
    addConsoleCommand("rmShow", "Reactive Markets: list buyer factors [fillType]", "consoleShow", RM)
    addConsoleCommand("rmReset", "Reactive Markets: reset all buyer factors to 1.00", "consoleReset", RM)
end

function RM:deleteMap()
    g_messageCenter:unsubscribeAll(RM)
    removeConsoleCommand("rmShow")
    removeConsoleCommand("rmReset")
    RM.hunger = {}
    RM.volume = {}
    RM.history = {}
    RM.dirty = {}
    RM.syncTimer = 0
    RM.saleLog = {}
    RM.unloads = {}
    RM.known = {}
    RM.loaded = false
end

function RM:update(dt)
    if not RM.loaded and g_currentMission ~= nil and g_currentMission.isMissionStarted then
        if g_currentMission:getIsServer() then
            RM.load()
        else
            RM.loaded = true
        end
    end
    if RM.isServer() and next(RM.unloads) ~= nil then
        RM.finishUnloads(false)
    end
    if RM.settings.debug and next(RM.saleLog) ~= nil then
        RM.flushSaleLog(false)
    end
    if RM.isServer() and next(RM.dirty) ~= nil then
        RM.syncTimer = RM.syncTimer + dt
        if RM.syncTimer >= RM.SYNC_INTERVAL then
            RM.syncTimer = 0
            RM.sendDirty()
        end
    end
end

function RM:onHourChanged()
    if g_currentMission ~= nil and g_currentMission:getIsServer() then
        RM.recoverHour()
    end
    RM.sampleHistory()   -- every machine keeps its own graph history
end

function RM:consoleShow(fillTypeName)
    local ftFilter = nil
    if fillTypeName ~= nil and fillTypeName ~= "" then
        ftFilter = g_fillTypeManager:getFillTypeIndexByName(string.upper(fillTypeName))
        if ftFilter == nil then
            return "Unknown fill type: " .. tostring(fillTypeName)
        end
    end
    local lines = {}
    for _, station in ipairs(RM.getStations()) do
        for ft, _ in pairs(station.acceptedFillTypes) do
            local h = RM.getHunger(station, ft)
            if (ftFilter ~= nil and ft == ftFilter) or (ftFilter == nil and h ~= 1.0) then
                local price = station:getEffectiveFillTypePrice(ft) or 0
                table.insert(lines, string.format("%-12s %-35s factor %.3f  price %8.0f /1000 l",
                    g_fillTypeManager:getFillTypeNameByIndex(ft) or "?", RM.getStationName(station), h, price * 1000))
            end
        end
    end
    table.sort(lines)
    for _, l in ipairs(lines) do
        print(l)
    end
    return string.format("%d entries (%s)", #lines, ftFilter ~= nil and "all buyers" or "only changed factors; add a fill type to see all")
end

function RM:consoleReset()
    if not RM.isServer() then
        return "rmReset only works on the server / host"
    end
    RM.hunger = {}
    RM.volume = {}
    RM.dirty = {}
    if g_server ~= nil then
        g_server:broadcastEvent(ReactiveMarketsSyncEvent.new({}, true))   -- clients clear too
    end
    return "All buyer factors reset to 1.00 and allowances refilled"
end

addModEventListener(RM)
