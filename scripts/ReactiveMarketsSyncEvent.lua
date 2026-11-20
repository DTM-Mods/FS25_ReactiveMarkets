-- Reactive Markets (PropaineX): server -> client sync of the price factors.
-- The server works out every factor; clients only receive them so their prices screen
-- (SellingStation.getEffectiveFillTypePrice) shows the same prices the server pays.
--   full = true : the complete table (sent to a player who joins); the client clears its own first
--   full = false: only the entries that changed since the last send (factor 1.0 = back to normal)

ReactiveMarketsSyncEvent = {}
local ReactiveMarketsSyncEvent_mt = Class(ReactiveMarketsSyncEvent, Event)
InitEventClass(ReactiveMarketsSyncEvent, "ReactiveMarketsSyncEvent")

function ReactiveMarketsSyncEvent.emptyNew()
    return Event.new(ReactiveMarketsSyncEvent_mt)
end

-- entries = { {station = <SellingStation>, fillType = <index>, factor = <number>}, ... }
function ReactiveMarketsSyncEvent.new(entries, full)
    local self = ReactiveMarketsSyncEvent.emptyNew()
    self.entries = entries or {}
    self.full = full == true
    return self
end

function ReactiveMarketsSyncEvent:writeStream(streamId, connection)
    streamWriteBool(streamId, self.full)
    streamWriteInt32(streamId, #self.entries)
    for _, e in ipairs(self.entries) do
        NetworkUtil.writeNodeObject(streamId, e.station)
        streamWriteUIntN(streamId, e.fillType, FillTypeManager.SEND_NUM_BITS)
        streamWriteFloat32(streamId, e.factor)
        streamWriteFloat32(streamId, e.volume or 0)   -- liters taken lately (free allowance on the ESC page)
    end
end

function ReactiveMarketsSyncEvent:readStream(streamId, connection)
    self.full = streamReadBool(streamId)
    local n = streamReadInt32(streamId)
    self.entries = {}
    for _ = 1, n do
        local station = NetworkUtil.readNodeObject(streamId)
        local ft = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS)
        local factor = streamReadFloat32(streamId)
        local volume = streamReadFloat32(streamId)
        if station ~= nil then   -- unknown object on this client: read past it, skip it
            table.insert(self.entries, { station = station, fillType = ft, factor = factor, volume = volume })
        end
    end
    self:run(connection)
end

function ReactiveMarketsSyncEvent:run(connection)
    -- only clients accept this, and only from the server
    if connection:getIsServer() and ReactiveMarkets ~= nil then
        ReactiveMarkets.applySync(self.entries, self.full)
    end
end
