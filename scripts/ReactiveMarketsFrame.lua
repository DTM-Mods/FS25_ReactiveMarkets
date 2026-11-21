-- Reactive Markets (PropaineX): the "Reactive Markets" page in the ESC menu, right under Production Chains.
-- Design: previews/page_croplist_v1.png (user OK'd 2026-11-19, "build it like this").
--   left     : your crops (icon, name, how much you have); D on the bottom bar shows every crop instead
--   MARKET   : the selected crop's buyers with price, change from normal, free allowance left and a 6-day graph
--   HISTORY  : the selected crop, one big graph with every buyer's line over the last 6 in-game days
--   SETTINGS : the numbers the market runs on (read only; edit modSettings/FS25_ReactiveMarkets.xml)
-- Header and tabs come from GUI XML; everything in the content area is drawn here with drawFilledRect/renderText.

ReactiveMarketsFrame = {}
local RMF = ReactiveMarketsFrame
local RMF_mt = Class(RMF, TabbedMenuFrameElement)

RMF.PAGE_NAME = "pageReactiveMarkets"
RMF.ICON_FILENAME = "gui/rm_tabIcon.dds"
RMF.ICON_SIZE = 256
RMF.TAB_MARKET, RMF.TAB_HISTORY, RMF.TAB_SETTINGS = 1, 2, 3
RMF.MAX_ROWS = 8      -- top buyers only, best price first (user: you only need the top ones)

-- Shapes from drawFilledRect come out much brighter than text with the same numbers (seen in game 2026-11-19:
-- 0.17 grey rows looked light grey), so shape colours are written as sRGB and converted to linear here.
local function lin(r, g, b, a)
    return {(r / 255) ^ 2.2, (g / 255) ^ 2.2, (b / 255) ^ 2.2, a or 1}
end
local UP = {0.59, 0.84, 0.16, 1}          -- text
local DOWN = {0.92, 0.33, 0.27, 1}        -- text
local WHITE = {0.92, 0.92, 0.90, 1}       -- text
local GREY = {0.62, 0.62, 0.62, 1}        -- text
local DARK = {0, 0, 0, 1}                 -- text on the green rows (0.10 looked faded olive in game 2026-11-19)
local R_GREEN = lin(130, 171, 13)         -- the game's highlight green
local R_ROW1 = lin(43, 43, 43)            -- the game's list stripes
local R_ROW2 = lin(52, 52, 52)
local R_TRACK = lin(80, 80, 80)
local R_TRACK_ON_GREEN = lin(70, 92, 8)
local R_FILL = lin(22, 175, 210)          -- allowance bars: the game's HUD blue (user 2026-11-19, less green)
local R_DARK = lin(25, 25, 25)
local R_UP = lin(150, 215, 40)
local R_DOWN = lin(235, 85, 70)
local R_MID = lin(95, 95, 95)
local R_GRID = lin(60, 60, 60)
local LINES = { lin(150, 215, 40), lin(80, 165, 240), lin(240, 190, 50), lin(205, 115, 230),
    lin(80, 215, 205), lin(240, 140, 75), lin(215, 215, 215), lin(140, 190, 115) }
local LINES_TEXT = { {0.59, 0.84, 0.16, 1}, {0.31, 0.65, 0.94, 1}, {0.94, 0.75, 0.20, 1}, {0.80, 0.45, 0.90, 1},
    {0.31, 0.84, 0.80, 1}, {0.94, 0.55, 0.29, 1}, {0.84, 0.84, 0.84, 1}, {0.55, 0.75, 0.45, 1} }

-- Price advice, same bands as the Price Ticker mod (sell now / consider / better wait / wait), user 2026-11-19.
-- % = this month's point on the game's yearly price line (fillType.economy.history, the Prices graph)
--     divided by the highest point of that line.
RMF.BANDS = {
    {min = 95, range = "95% or more", label = "Sell now", advice = "SELL NOW", color = {0.59, 0.84, 0.16, 1}, rect = lin(150, 215, 40)},
    {min = 90, range = "90 - 95%", label = "Consider selling", advice = "CONSIDER SELLING", color = {0.94, 0.80, 0.16, 1}, rect = lin(240, 205, 40)},
    {min = 75, range = "75 - 90%", label = "Better wait", advice = "BETTER WAIT", color = {0.96, 0.55, 0.16, 1}, rect = lin(245, 140, 40)},
    {min = -1, range = "under 75%", label = "Wait", advice = "WAIT", color = {0.92, 0.29, 0.24, 1}, rect = lin(235, 75, 60)},
}

function RMF.getYearBand(ft)
    local fillType = g_fillTypeManager:getFillTypeByIndex(ft)
    local economy = fillType ~= nil and fillType.economy or nil
    if economy == nil then
        return nil
    end
    local periods = Environment ~= nil and Environment.PERIODS_IN_YEAR or 12
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local current = env ~= nil and env.currentPeriod or nil
    if current == nil then
        return nil
    end
    local maxV, curV = 0, nil
    for period = 1, periods do
        local v = economy.history ~= nil and economy.history[period] or nil
        if v == nil and economy.factors ~= nil then
            v = (economy.factors[period] or 1) * (fillType.pricePerLiter or 0)
        end
        if v ~= nil then
            maxV = math.max(maxV, v)
            if period == current then
                curV = v
            end
        end
    end
    if curV == nil or maxV <= 0 then
        return nil
    end
    local percent = math.min(100, curV / maxV * 100)
    for _, b in ipairs(RMF.BANDS) do
        if percent >= b.min then
            return {percent = percent, color = b.color, advice = b.advice}
        end
    end
    return nil
end

-- buyers the game's own Prices screen shows (storage-only stations such as the Logistics Hub depots set
-- hideFromPricesMenu, user 2026-11-19: "it's not a sell point")
local function isListed(station)
    return station.hideFromPricesMenu ~= true
end

RMF.instance = nil

function RMF.new()
    local self = RMF:superClass().new(nil, RMF_mt)
    self.hasCustomMenuButtons = true
    self.tab = RMF.TAB_MARKET
    self.fillTypes = {}
    self.ftIndex = 1
    return self
end

----------------------------------------------------------------------------------------------------------------
-- Adding the page to the ESC menu, right under Production Chains
----------------------------------------------------------------------------------------------------------------

local function moveToPosition(list, item, position, getItem)
    for i = 1, #list do
        if getItem(list[i]) == item then
            local entry = table.remove(list, i)
            table.insert(list, math.min(position, #list + 1), entry)
            return
        end
    end
end

function RMF.getIconUVs()
    return GuiUtils.getUVs({0, 0, RMF.ICON_SIZE, RMF.ICON_SIZE}, {RMF.ICON_SIZE, RMF.ICON_SIZE})
end

local function isProductionPage(element)
    return InGameMenuProductionFrame ~= nil and type(element) == "table" and element.isa ~= nil
        and element:isa(InGameMenuProductionFrame)
end

function RMF.register()
    if RMF.instance ~= nil or g_gui == nil then
        return
    end
    local inGameMenu = g_gui.screenControllers[InGameMenu]
    if inGameMenu == nil or inGameMenu.pagingElement == nil or inGameMenu.registerPage == nil or inGameMenu.addPageTab == nil then
        print("[ReactiveMarkets] the ESC menu can't take new pages, the Reactive Markets page is not added")
        return
    end

    local frame = RMF.new()
    g_gui:loadGui(ReactiveMarkets.MOD_DIR .. "gui/ReactiveMarketsFrame.xml", "ReactiveMarketsFrame", frame, true)

    local pageName = RMF.PAGE_NAME
    inGameMenu.controlIDs[pageName] = nil
    inGameMenu[pageName] = frame
    inGameMenu.pagingElement:addElement(frame)
    inGameMenu:exposeControlsAsFields(pageName)

    -- right after the Production Chains page (user, 2026-11-19), or at the end
    local position = #inGameMenu.pagingElement.elements
    local found = false
    for i, element in ipairs(inGameMenu.pagingElement.elements) do
        if element ~= frame and (isProductionPage(element) or element == inGameMenu.pageProduction) then
            position = i + 1
            found = true
            break
        end
    end

    moveToPosition(inGameMenu.pagingElement.elements, frame, position, function(element) return element end)
    moveToPosition(inGameMenu.pagingElement.pages, frame, position, function(page) return page.element end)
    inGameMenu.pagingElement:updateAbsolutePosition()
    inGameMenu.pagingElement:updatePageMapping()

    inGameMenu:registerPage(frame, position, function() return true end)
    inGameMenu:addPageTab(frame, ReactiveMarkets.MOD_DIR .. RMF.ICON_FILENAME, RMF.getIconUVs())
    if inGameMenu.pageFrames ~= nil then
        moveToPosition(inGameMenu.pageFrames, frame, position, function(element) return element end)
    end
    inGameMenu:rebuildTabList()

    frame:initialize()
    RMF.instance = frame
    print(string.format("[ReactiveMarkets] ESC page added at position %d (%s)", position,
        found and "under Production Chains" or "Production Chains page not found, added at the end"))
end

----------------------------------------------------------------------------------------------------------------
-- Your stock: only what the farm can load out and sell (user, 2026-11-19)
--   counts: silos + silo extensions, production OUTPUTS, animal-pen outputs (milk, slurry, manure...),
--           own pallets / vehicles / trailers (not their fuel), own bales
--   skips : feeding robots, animal food / straw / water, production inputs, Logistics Hub depots (ignored mods)
----------------------------------------------------------------------------------------------------------------

local MOTOR_FILLTYPES = {"DIESEL", "DEF", "AIR", "ELECTRICCHARGE", "METHANE"}

function RMF.getFarmStock(farmId)
    local stock = {}
    local mission = g_currentMission
    if mission == nil or farmId == nil then
        return stock
    end
    local function add(ft, level)
        if ft ~= nil and level ~= nil and level > 0.5 then
            stock[ft] = (stock[ft] or 0) + level
        end
    end
    local function addStorage(storage, skip, only)
        if storage ~= nil and storage.fillLevels ~= nil then
            for ft, level in pairs(storage.fillLevels) do
                if (only == nil or only[ft]) and (skip == nil or not skip[ft]) then
                    add(ft, level)
                end
            end
        end
    end
    local ignored = ReactiveMarkets.IGNORED_MODS or {}

    local placeableSystem = mission.placeableSystem
    for _, p in ipairs(placeableSystem ~= nil and placeableSystem.placeables or {}) do
        if p.getOwnerFarmId ~= nil and p:getOwnerFarmId() == farmId and not ignored[p.customEnvironment or ""] then
            if p.spec_silo ~= nil then
                for _, storage in ipairs(p.spec_silo.storages or {}) do
                    addStorage(storage)
                end
            end
            if p.spec_siloExtension ~= nil then
                addStorage(p.spec_siloExtension.storage)
            end
            local pp = p.spec_productionPoint ~= nil and p.spec_productionPoint.productionPoint or nil
            if pp ~= nil and pp.outputFillTypeIds ~= nil then
                addStorage(pp.storage, nil, pp.outputFillTypeIds)
            end
            if p.spec_husbandry ~= nil and p.spec_husbandry.storage ~= nil then
                local skip = {}
                if p.spec_husbandryStraw ~= nil and p.spec_husbandryStraw.inputFillType ~= nil then
                    skip[p.spec_husbandryStraw.inputFillType] = true
                end
                if p.spec_husbandryWater ~= nil and p.spec_husbandryWater.fillType ~= nil then
                    skip[p.spec_husbandryWater.fillType] = true
                end
                if p.spec_husbandryFood ~= nil and p.spec_husbandryFood.fillLevels ~= nil then
                    for ft in pairs(p.spec_husbandryFood.fillLevels) do
                        skip[ft] = true
                    end
                end
                addStorage(p.spec_husbandry.storage, skip)
            end
        end
    end

    -- own pallets, trailers and vehicles (pallets are vehicles too); a motorized vehicle's fuel does not count
    local motor = {}
    for _, name in ipairs(MOTOR_FILLTYPES) do
        local ft = g_fillTypeManager:getFillTypeIndexByName(name)
        if ft ~= nil then
            motor[ft] = true
        end
    end
    local vehicleSystem = mission.vehicleSystem
    for _, v in ipairs(vehicleSystem ~= nil and vehicleSystem.vehicles or {}) do
        if v.getOwnerFarmId ~= nil and v:getOwnerFarmId() == farmId and v.spec_fillUnit ~= nil then
            local isMotorized = v.spec_motorized ~= nil
            for _, unit in ipairs(v.spec_fillUnit.fillUnits or {}) do
                local ft = unit.fillType
                if ft ~= nil and ft ~= FillType.UNKNOWN and not (isMotorized and motor[ft]) then
                    add(ft, unit.fillLevel)
                end
            end
        end
    end

    -- own bales
    local itemSystem = mission.itemSystem
    for _, object in pairs(itemSystem ~= nil and itemSystem.itemsToSave or {}) do
        local item = type(object) == "table" and (object.item or object) or nil
        if item ~= nil and item.isa ~= nil and Bale ~= nil and item:isa(Bale)
            and item.getOwnerFarmId ~= nil and item:getOwnerFarmId() == farmId then
            add(item.fillType, item.fillLevel)
        end
    end
    return stock
end

----------------------------------------------------------------------------------------------------------------
-- Frame
----------------------------------------------------------------------------------------------------------------

RMF.LIST_ROWS = 11
RMF.REFRESH_MS = 2000

function RMF:initialize()
    self.backButtonInfo = {inputAction = InputAction.MENU_BACK}
    -- D, like "show hidden" on the Inventory page
    self.allButtonInfo = {inputAction = InputAction.MENU_EXTRA_3, text = "SHOW ALL CROPS", callback = function()
        self.showAll = not self.showAll
        self.listOffset = 0
        self:refreshData(true)
        self:updateButtons()
    end}
    if self.headerIcon ~= nil then
        self.headerIcon:setImageFilename(ReactiveMarkets.MOD_DIR .. RMF.ICON_FILENAME)
        self.headerIcon:setImageUVs(nil, unpack(RMF.getIconUVs()))
    end
    self.showAll = false
    self.listOffset = 0
    self.crops = {}
    self.stock = {}
end

function RMF:onFrameOpen(element)
    RMF:superClass().onFrameOpen(self)
    self:refreshData(true)
    self:showTab(self.tab)
end

function RMF:updateButtons()
    local buttons = {self.backButtonInfo}
    if self.tab ~= RMF.TAB_SETTINGS then
        self.allButtonInfo.text = self.showAll and "SHOW ONLY MY CROPS" or "SHOW ALL CROPS"
        table.insert(buttons, self.allButtonInfo)
    end
    self:setMenuButtonInfo(buttons)
    self:setMenuButtonInfoDirty()
end

function RMF:showTab(tab)
    self.tab = tab
    for i, button in ipairs(self.tabs or {}) do
        button:setSelected(i == tab)
    end
    self:updateButtons()
end

function RMF:onClickTabMarket() self:showTab(RMF.TAB_MARKET) end
function RMF:onClickTabHistory() self:showTab(RMF.TAB_HISTORY) end
function RMF:onClickTabSettings() self:showTab(RMF.TAB_SETTINGS) end

local function getLocalFarmId()
    return g_currentMission ~= nil and g_currentMission.getFarmId ~= nil and g_currentMission:getFarmId() or nil
end

-- the crop list: crops some listed buyer pays for, and (unless "show all") that the farm has in stock
function RMF:refreshData(force)
    if not force and self.lastRefresh ~= nil and g_time - self.lastRefresh < RMF.REFRESH_MS then
        return
    end
    self.lastRefresh = g_time
    self.stock = RMF.getFarmStock(getLocalFarmId())

    local buyers = {}
    for _, station in ipairs(ReactiveMarkets.getStations()) do
        if isListed(station) then
            for ft, _ in pairs(station.acceptedFillTypes) do
                if (station:getEffectiveFillTypePrice(ft) or 0) > 0 then
                    buyers[ft] = (buyers[ft] or 0) + 1
                end
            end
        end
    end
    local crops = {}
    for ft, n in pairs(buyers) do
        local fillType = g_fillTypeManager:getFillTypeByIndex(ft)
        local have = self.stock[ft] or 0
        if fillType ~= nil and (self.showAll and n >= 1 or have > 0) then
            table.insert(crops, {index = ft, title = fillType.title or fillType.name or tostring(ft), have = have})
        end
    end
    table.sort(crops, function(a, b) return a.title < b.title end)
    self.crops = crops

    -- keep the selected crop if it is still there, else the first one
    local found = false
    for _, c in ipairs(crops) do
        if c.index == self.selectedFt then
            found = true
            break
        end
    end
    if not found then
        self.selectedFt = crops[1] ~= nil and crops[1].index or nil
    end
    local maxOffset = math.max(0, #crops - RMF.LIST_ROWS)
    self.listOffset = math.max(0, math.min(self.listOffset or 0, maxOffset))
end

-- rows for one crop: name, price per 1000 l, normal price, factor, allowance left, history; best price first
function RMF:getRows(ft)
    local rows = {}
    local RM = ReactiveMarkets
    for _, station in ipairs(RM.getStations()) do
        if isListed(station) and station.acceptedFillTypes[ft] then
            local price = station:getEffectiveFillTypePrice(ft) or 0
            if price > 0 then
                local factor = RM.getHunger(station, ft)
                local vt = RM.volume[station]
                local taken = vt ~= nil and vt[ft] or 0
                table.insert(rows, {
                    name = RM.getStationName(station),
                    price = price * 1000,
                    normal = price * 1000 / factor,
                    factor = factor,
                    allowanceLeft = math.max(0, RM.settings.allowanceLiters - taken),
                    history = RM.getHistory(station, ft),
                })
            end
        end
    end
    table.sort(rows, function(a, b)
        if math.abs(a.price - b.price) > 0.001 then
            return a.price > b.price
        end
        return a.name < b.name
    end)
    return rows
end

----------------------------------------------------------------------------------------------------------------
-- Drawing helpers
----------------------------------------------------------------------------------------------------------------

local function rect(x, y, w, h, c)
    drawFilledRect(x, y, w, h, c[1], c[2], c[3], c[4])
end

-- Horizontal reference unit. u is a share of the screen HEIGHT, x positions are shares of the screen WIDTH, so a
-- horizontal gap written as n * u grew with the aspect ratio (32:9 in game 2026-11-21: the buyer column shrank
-- to nothing and every name showed as "G...", "P..."). ux equals u on 16:9 (the layout was tuned there) and
-- keeps the same on-screen size on wider and narrower screens.
local function hUnit(u)
    return u * (16 / 9) / g_screenAspectRatio
end

local function text(x, y, size, str, c, align, bold)
    setTextBold(bold == true)
    setTextColor(c[1], c[2], c[3], c[4])
    setTextAlignment(align or RenderText.ALIGN_LEFT)
    setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_MIDDLE)
    renderText(x, y, size, str)
end

local function resetText()
    setTextBold(false)
    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_BASELINE)
end

local function money(v)
    return g_i18n ~= nil and g_i18n.formatMoney ~= nil and g_i18n:formatMoney(v, 0, true, true) or string.format("$ %d", v)
end

local function liters(v)
    return string.format("%s l", g_i18n:formatNumber(v, 0))
end

local function fit(str, size, maxW)
    if getTextWidth(size, str) <= maxW then
        return str
    end
    while #str > 1 and getTextWidth(size, str .. "...") > maxW do
        str = string.sub(str, 1, -2)
    end
    return str .. "..."
end

local function pctText(factor)
    local pct = (factor - 1) * 100
    if math.abs(pct) < 0.05 then
        return "-", WHITE, nil
    end
    return string.format("%+.1f%%", pct), pct > 0 and UP or DOWN, pct > 0 and R_UP or R_DOWN
end

-- a line graph made of small squares; values are factors, the middle of the box is 1.00
local function graph(x, y, w, h, values, c, range, dot)
    local n = #values
    if n < 2 then
        return
    end
    local sx = dot / g_screenAspectRatio
    local steps = math.max(n - 1, 1)
    local samples = math.max(math.floor(w / sx), 2)
    for s = 0, samples do
        local p = s / samples * steps + 1
        local i = math.min(math.floor(p), n - 1)
        local v = values[i] + (values[i + 1] - values[i]) * (p - i)
        local ny = math.max(-1, math.min(1, (v - 1) / range))
        rect(x + w * s / samples - sx / 2, y + h / 2 + ny * h / 2 - dot / 2, sx, dot, c)
    end
end

-- one Overlay per fill type icon (fillType.hudOverlayFilename), made once and kept
function RMF:getCropIcon(fillType)
    if fillType == nil or fillType.hudOverlayFilename == nil or fillType.hudOverlayFilename == "" or Overlay == nil then
        return nil
    end
    self.cropIcons = self.cropIcons or {}
    local icon = self.cropIcons[fillType.index]
    if icon == nil then
        icon = Overlay.new(fillType.hudOverlayFilename, 0, 0, 0, 0)
        self.cropIcons[fillType.index] = icon
    end
    return icon
end

function RMF:drawIcon(fillType, x, cy, h)
    local icon = self:getCropIcon(fillType)
    if icon ~= nil then
        local w = h / g_screenAspectRatio
        icon:setPosition(x, cy - h / 2)
        icon:setDimension(w, h)
        icon:render()
        return w
    end
    return 0
end

----------------------------------------------------------------------------------------------------------------
-- Mouse: click a crop in the list, mouse wheel scrolls the list
----------------------------------------------------------------------------------------------------------------

function RMF:mouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    if self:getIsVisible() and self.tab ~= RMF.TAB_SETTINGS and self.listBox ~= nil and not eventUsed then
        local b = self.listBox
        if posX >= b.x and posX <= b.x + b.w and posY >= b.y and posY <= b.y + b.h then
            if isDown and (button == Input.MOUSE_BUTTON_WHEEL_UP or button == Input.MOUSE_BUTTON_WHEEL_DOWN) then
                local dir = button == Input.MOUSE_BUTTON_WHEEL_UP and -1 or 1
                local maxOffset = math.max(0, #self.crops - RMF.LIST_ROWS)
                self.listOffset = math.max(0, math.min((self.listOffset or 0) + dir, maxOffset))
                eventUsed = true
            elseif isDown and button == Input.MOUSE_BUTTON_LEFT then
                for _, r in ipairs(self.rowBoxes or {}) do
                    if posY >= r.y and posY <= r.y + r.h then
                        self.selectedFt = r.ft
                        eventUsed = true
                        break
                    end
                end
            end
        end
        self.hoverFt = nil
        if posX >= b.x and posX <= b.x + b.w then
            for _, r in ipairs(self.rowBoxes or {}) do
                if posY >= r.y and posY <= r.y + r.h then
                    self.hoverFt = r.ft
                end
            end
        end
    end
    return RMF:superClass().mouseEvent(self, posX, posY, isDown, isUp, button, eventUsed) or eventUsed
end

----------------------------------------------------------------------------------------------------------------
-- Drawing
----------------------------------------------------------------------------------------------------------------

function RMF:draw()
    RMF:superClass().draw(self)
    if self.content == nil or not self:getIsVisible() then
        return
    end
    local x, y = self.content.absPosition[1], self.content.absPosition[2]
    local w, h = self.content.absSize[1], self.content.absSize[2]
    if w <= 0 or h <= 0 then
        return
    end
    local top = y + h
    local u = h / 680   -- one reference pixel (vertical)

    if self.tab == RMF.TAB_SETTINGS then
        self.listBox = nil
        self:drawSettings(x, top, w, u)
        resetText()
        return
    end

    self:refreshData(false)
    local listW = w * 0.31
    self:drawCropList(x, top, listW, u)

    local rx, rw = x + listW + w * 0.025, w - listW - w * 0.025
    local ft = self.selectedFt
    if ft == nil then
        text(rx, top - 30 * u, 18 * u, self.showAll and "No buyers found yet." or
            "You have nothing in stock that a buyer takes. Press the button on the bottom bar to show all crops.", GREY)
    else
        local rows = self:getRows(ft)
        self:drawCropHeader(rx, top, rw, u, ft, rows)
        if self.tab == RMF.TAB_MARKET then
            self:drawMarket(rx, top - 82 * u, rw, u, rows)
        else
            self:drawHistory(rx, top - 82 * u, rw, h - 100 * u, u, rows)
        end
    end
    resetText()
end

function RMF:drawCropList(x, top, w, u)
    local ux = hUnit(u)
    local headY = top - 12 * u
    text(x + 10 * ux, headY, 15 * u, self.showAll and "ALL CROPS" or "YOUR CROPS", GREY, RenderText.ALIGN_LEFT, true)
    text(x + w - 18 * ux, headY, 15 * u, "YOU HAVE", GREY, RenderText.ALIGN_RIGHT, true)
    rect(x, top - 26 * u, w, 1 * u, R_GRID)

    local rowH = 43 * u
    local listTop = top - 32 * u
    local n = #self.crops
    local shown = math.min(RMF.LIST_ROWS, n - self.listOffset)
    self.rowBoxes = {}
    self.listBox = {x = x, y = listTop - RMF.LIST_ROWS * rowH, w = w, h = RMF.LIST_ROWS * rowH}
    local barW = 5 * ux
    for i = 1, shown do
        local c = self.crops[self.listOffset + i]
        local rt = listTop - (i - 1) * rowH
        local cy = rt - rowH / 2
        local sel = c.index == self.selectedFt
        local bg = sel and R_GREEN or (c.index == self.hoverFt and lin(62, 62, 62) or ((self.listOffset + i) % 2 == 0 and R_ROW2 or R_ROW1))
        rect(x, rt - rowH + 2 * u, w - barW * 3, rowH - 2 * u, bg)
        local fillType = g_fillTypeManager:getFillTypeByIndex(c.index)
        local iw = self:drawIcon(fillType, x + 8 * ux, cy, 31 * u)
        local tc = sel and DARK or WHITE
        local amount = c.have > 0 and liters(c.have) or "-"
        local amountW = getTextWidth(17 * u, amount)
        text(x + 16 * ux + iw, cy, 20 * u, fit(c.title, 20 * u, w - iw - amountW - 60 * ux), tc, RenderText.ALIGN_LEFT, true)
        text(x + w - barW * 3 - 10 * ux, cy, 17 * u, amount, sel and DARK or GREY, RenderText.ALIGN_RIGHT)
        table.insert(self.rowBoxes, {y = rt - rowH, h = rowH, ft = c.index})
    end
    -- scroll bar
    if n > RMF.LIST_ROWS then
        local trackH = RMF.LIST_ROWS * rowH
        local thumbH = trackH * RMF.LIST_ROWS / n
        local thumbY = listTop - (self.listOffset / (n - RMF.LIST_ROWS)) * (trackH - thumbH) - thumbH
        rect(x + w - barW, listTop - trackH, barW, trackH, R_GRID)
        rect(x + w - barW, thumbY, barW, thumbH, lin(150, 150, 150))
    end
    local footY = listTop - RMF.LIST_ROWS * rowH - 20 * u
    text(x + 10 * ux, footY, 13 * u, self.showAll and "Every crop a buyer takes." or
        "Only crops you have and can sell (no robots, no production inputs).", GREY)
end

-- crop icon + name + how much you have; best buyer and normal price on the line under it
function RMF:drawCropHeader(x, top, w, u, ft, rows)
    local fillType = g_fillTypeManager:getFillTypeByIndex(ft)
    local title = fillType ~= nil and (fillType.title or fillType.name) or "?"
    local ux = hUnit(u)
    local cy = top - 16 * u
    local iw = self:drawIcon(fillType, x, cy, 34 * u)
    local tx = x + (iw > 0 and iw + 10 * ux or 0)
    setTextBold(true)
    text(tx, cy, 26 * u, title, WHITE, RenderText.ALIGN_LEFT, true)
    local have = self.stock[ft] or 0
    setTextBold(true)
    local titleW = getTextWidth(26 * u, title)
    text(tx + titleW + 18 * ux, cy, 16 * u, have > 0 and ("you have " .. liters(have)) or "you have none", GREY)
    local best = rows[1]
    if best ~= nil then
        local lsize = 16 * u
        -- the whole line in the band colour, the advice centred under it at 75 % size (mockup page_pricecolor_v7)
        local band = RMF.getYearBand(ft)
        local normal = "NORMAL PRICE TODAY:  " .. money(best.normal) ..
            (band ~= nil and string.format("  (%d%%)", math.floor(band.percent + 0.5)) or "")
        local color = band ~= nil and band.color or GREY
        setTextBold(true)
        local normalW = getTextWidth(lsize, normal)
        text(x + w, cy, lsize, normal, color, RenderText.ALIGN_RIGHT, true)
        if band ~= nil then
            text(x + w - normalW / 2, cy - 20 * u, lsize * 0.75, band.advice, color, RenderText.ALIGN_CENTER, true)
        end
        local pct = pctText(best.factor)
        local prefix = "BEST PLACE TO SELL:  "
        local suffix = string.format("  -  %s / 1,000 l%s", money(best.price), pct ~= "-" and ("  (" .. pct .. ")") or "")
        setTextBold(true)
        local room = w - getTextWidth(lsize, prefix .. suffix)
        text(x, top - 50 * u, lsize, prefix .. fit(best.name, lsize, room) .. suffix, UP, RenderText.ALIGN_LEFT, true)
    end
end

-- "6 MONTHS": the graphs cover 6 in-game days; in months that depends on the days-per-month setting
-- (the server's on a server), e.g. 1 day per month = 6 months, 3 days per month = 2 months (user 2026-11-19)
function RMF.getGraphSpanText()
    local days = ReactiveMarkets.HISTORY_HOURS / 24
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local perMonth = env ~= nil and env.daysPerPeriod or nil
    if perMonth == nil or perMonth <= 0 then
        return string.format("%d DAYS", days)
    end
    local months = days / perMonth
    local m
    if math.abs(months - math.floor(months + 0.5)) < 0.01 then
        m = string.format("%d", math.floor(months + 0.5))
    else
        m = string.format("%.1f", months)
    end
    return string.format("%s %s", m, m == "1" and "MONTH" or "MONTHS")   -- user: months only, spelled out
end

function RMF:drawMarket(x, top, w, u, rows)
    local ux = hUnit(u)
    local cName, cPrice, cPct, cBar, cGraph = x + 14 * ux, x + w * 0.40, x + w * 0.53, x + w * 0.62, x + w * 0.84
    local headY = top - 4 * u
    text(cName, headY, 16 * u, "BUYER", GREY, RenderText.ALIGN_LEFT, true)
    text(cPrice, headY, 16 * u, "PRICE / 1,000 l", GREY, RenderText.ALIGN_CENTER, true)
    text(cPct, headY, 16 * u, "VS NORMAL", GREY, RenderText.ALIGN_CENTER, true)
    text(cBar, headY, 16 * u, "ALLOWANCE LEFT", GREY, RenderText.ALIGN_LEFT, true)
    -- shrink the span header if it would run past the table edge (e.g. "6 DAYS / 1.5 MONTHS")
    local span = RMF.getGraphSpanText()
    local spanSize = 16 * u
    setTextBold(true)
    local spanW = getTextWidth(spanSize, span)
    if spanW > x + w - cGraph then
        spanSize = spanSize * (x + w - cGraph) / spanW
    end
    text(cGraph, headY, spanSize, span, GREY, RenderText.ALIGN_LEFT, true)

    local rowH = 48 * u
    local allowance = math.max(ReactiveMarkets.settings.allowanceLiters, 1)
    local shown = math.min(#rows, RMF.MAX_ROWS)
    for i = 1, shown do
        local r = rows[i]
        local rowTop = top - 20 * u - (i - 1) * rowH
        local cy = rowTop - rowH / 2
        local best = i == 1
        rect(x, rowTop - rowH + 3 * u, w, rowH - 3 * u, best and R_GREEN or (i % 2 == 0 and R_ROW2 or R_ROW1))
        local pct, pctColor, lineColor = pctText(r.factor)
        local tc = best and DARK or WHITE
        text(cName, cy, 20 * u, fit(r.name, 20 * u, cPrice - cName - 80 * ux), tc, RenderText.ALIGN_LEFT, true)
        text(cPrice, cy, 20 * u, money(r.price), best and DARK or pctColor, RenderText.ALIGN_CENTER, true)
        text(cPct, cy, 20 * u, pct, best and DARK or pctColor, RenderText.ALIGN_CENTER, true)

        -- allowance bar (on the green row: white fill on a darker green track, so a full bar looks full)
        local barW, barH = w * 0.12, 10 * u
        rect(cBar, cy - barH / 2, barW, barH, best and R_TRACK_ON_GREEN or R_TRACK)
        local f = math.max(0, math.min(1, r.allowanceLeft / allowance))
        if f > 0 then
            rect(cBar, cy - barH / 2, barW * f, barH, best and lin(235, 235, 230) or R_FILL)
        end
        text(cBar + barW + 8 * ux, cy, 15 * u, liters(r.allowanceLeft), best and DARK or GREY)

        -- 6-day graph, centre line = normal price, top / bottom = the price limits
        local gw, gh = w * 0.14, rowH - 12 * u
        rect(cGraph, cy, gw, 1 * u, best and R_TRACK_ON_GREEN or R_MID)
        graph(cGraph, cy - gh / 2, gw, gh, r.history, best and R_DARK or (lineColor or R_MID), 0.15, 2.5 * u)
    end
    local footY = top - 20 * u - shown * rowH - 26 * u
    text(cName, footY, 13 * u, string.format("Prices move when one buyer takes more than its free allowance (%s).",
        liters(ReactiveMarkets.settings.allowanceLiters)), GREY)
    text(cName, footY - 20 * u, 13 * u, string.format("Rival buyers of the same crop then pay a little more. Back to normal in about %.0f in-game days.",
        ReactiveMarkets.settings.recoveryDays), GREY)

    -- key, two columns (user 2026-11-19)
    local ky = footY - 58 * u
    text(cName, ky, 14 * u, "NORMAL PRICE TODAY vs. the highest monthly price this year:", GREY, RenderText.ALIGN_LEFT, true)
    local colW = w * 0.40
    -- labels start after the widest range text (in-game 2026-11-19 they ran into "95% or more")
    setTextBold(true)
    local rangeW = 0
    for _, b in ipairs(RMF.BANDS) do
        rangeW = math.max(rangeW, getTextWidth(15 * u, b.range))
    end
    local box = 14 * u
    for i, b in ipairs(RMF.BANDS) do
        local col = i <= 2 and 0 or 1
        local yy = ky - 26 * u - ((i - 1) % 2) * 24 * u
        local xx = cName + col * colW
        rect(xx, yy - box / 2, box / g_screenAspectRatio, box, b.rect)
        local rx = xx + box / g_screenAspectRatio + 12 * ux
        text(rx, yy, 15 * u, b.range, b.color, RenderText.ALIGN_LEFT, true)
        text(rx + rangeW + 20 * ux, yy, 15 * u, b.label, WHITE)
    end
end

function RMF:drawHistory(x, top, w, h, u, rows)
    local ux = hUnit(u)
    local gx, gw = x + w * 0.07, w * 0.58
    local gh = h - 50 * u
    local gy = top - 10 * u - gh
    rect(gx, gy, gw, gh, R_ROW1)
    local range = 0.16
    for _, lv in ipairs({0.85, 0.90, 0.95, 1.00, 1.05, 1.10, 1.15}) do
        local ly = gy + gh / 2 + (lv - 1) / range * gh / 2
        rect(gx, ly, gw, 1 * u, lv == 1 and R_MID or R_GRID)
        text(gx - 8 * ux, ly, 13 * u, string.format("%+d%%", math.floor((lv - 1) * 100 + 0.5)), GREY, RenderText.ALIGN_RIGHT)
    end
    text(gx, gy - 14 * u, 13 * u, "6 days ago", GREY)
    text(gx + gw, gy - 14 * u, 13 * u, "now", GREY, RenderText.ALIGN_RIGHT)

    local lx = gx + gw + 24 * ux
    local maxName = x + w - lx - 90 * ux
    for i, r in ipairs(rows) do
        local ly = top - 10 * u - (i - 1) * 28 * u
        if i > #LINES then
            text(lx, ly, 14 * u, string.format("+ %d more", #rows - #LINES), GREY)
            break
        end
        graph(gx, gy, gw, gh, r.history, LINES[i], range, 3 * u)
        rect(lx, ly - 5 * u, 10 * ux, 10 * u, LINES[i])
        local pct = pctText(r.factor)
        text(lx + 18 * ux, ly, 15 * u, fit(r.name, 15 * u, maxName), LINES_TEXT[i])
        text(x + w, ly, 15 * u, pct, LINES_TEXT[i], RenderText.ALIGN_RIGHT, true)
    end
end

function RMF:drawSettings(x, top, w, u)
    local ux = hUnit(u)
    local s = ReactiveMarkets.settings
    local lines = {
        {"Free allowance per buyer and crop", liters(s.allowanceLiters)},
        {"Price limits", string.format("%.0f%%  to  +%.0f%%", (s.minHunger - 1) * 100, (s.maxHunger - 1) * 100)},
        {"Step at the buyer you sell to", string.format("%.0f%% of the gap per %s", s.sellerStep * 100, liters(s.batchLiters))},
        {"Step at every rival buyer", string.format("%.0f%% of the gap per %s", s.rivalStep * 100, liters(s.batchLiters))},
        {"Back to normal after", string.format("about %.0f in-game days", s.recoveryDays)},
        {"Debug log", s.debug and "on" or "off"},
    }
    for i, l in ipairs(lines) do
        local cy = top - 30 * u - (i - 1) * 40 * u
        rect(x, cy - 18 * u, w * 0.6, 37 * u, i % 2 == 0 and R_ROW2 or R_ROW1)
        text(x + 20 * ux, cy, 18 * u, l[1], WHITE, RenderText.ALIGN_LEFT, true)
        text(x + w * 0.6 - 20 * ux, cy, 18 * u, l[2], UP, RenderText.ALIGN_RIGHT, true)
    end
    local fy = top - 30 * u - #lines * 40 * u - 20 * u
    text(x, fy, 14 * u, "These are read when a savegame loads, from modSettings/FS25_ReactiveMarkets.xml (on a server: the server's copy).", GREY)
end
