-- Opening and closing chat's buffers, with what comes with each: its
-- history, its nick's presence (MONITOR), its channel's PART.

local bus        <const> = require 'hub.runtime.bus'
local clock      <const> = require 'hub.runtime.clock'
local common     <const> = require 'hub.features.common'
local history    <const> = require 'hub.features.chat.history'
local intent     <const> = require 'hub.net.intent'
local irc_model  <const> = require 'hub.net.irc'
local monitor    <const> = require 'hub.net.monitor'
local OrderedMap <const> = require 'hub.lib.OrderedMap'
local ratelimit  <const> = require 'hub.lib.ratelimit'
local store      <const> = require 'hub.features.chat.store'

local M = {}

local query <const> = common.sender 'chat'

-- History requests new buffers may make at once, and the seconds that
-- earn another
M.history_burst = 10
M.history_interval = 6

-- A private buffer watches its nick's presence with MONITOR
-- (net/monitor.lua, as 'chat') while it is open, by its current name.
-- Server and channel buffers watch nothing.
local function watches(net, irc, name)
    return not irc_model.is_channel_name(irc, name) and not store.is_server(net, name)
end

--- Watch a private buffer's nick.
---@param net string
---@param target string
function M.watch(net, target)
    local irc = store.model(net)
    if irc and watches(net, irc, target) then
        monitor.want(net, 'chat', target)
    end
end

--- Watch the nick of every private buffer, once registered.
---@param net string
function M.watch_all(net)
    local irc = store.model(net)
    ---@cast irc -nil registered, so connected
    local nicks = {}
    for _, buffer in pairs(store.get(net).buffers) do
        if watches(net, irc, buffer.name) then
            table.insert(nicks, buffer.name)
        end
    end
    monitor.want_all(net, 'chat', nicks)
end

--- A buffer, created (and its history requested) when missing.
---@param net string
---@param target string
---@param before string|nil server time of the message that opened it
---@return hub.ChatBuffer
function M.open(net, target, before)
    local C = store.get(net)
    local key = store.fold(net, target)
    local buffer = C.buffers[key]
    if buffer then
        buffer.name = target
        return buffer
    end
    buffer = {name = target, messages = OrderedMap.new(store.buffer_size), activity = 0, mention = false}
    C.buffers[key] = buffer
    -- what came before the message that opened it, or the latest; a flood
    -- of new senders gets a few such requests, not one each
    local now = clock.now()
    if not store.is_server(net, target)
    and ratelimit.wait(C.history_bucket or now, now, M.history_burst, M.history_interval) == 0 then
        C.history_bucket = ratelimit.take(C.history_bucket or now, now, M.history_interval)
        history.request(net, target, before and 'BEFORE' or 'LATEST', before)
    end
    bus.emit('chat.buffer', {net = net, target = target, opened = true})
    M.watch(net, target)
    return buffer
end

--- Forget a buffer, leaving its channel joined and its nick watched if
--- they still are.
---@param net string
---@param key string its folded name
---@param target string
function M.drop(net, key, target)
    store.get(net).buffers[key] = nil
    -- a channel's snapshot lasts as long as its buffer
    local irc = store.model(net)
    if irc then irc_model.forget_observed(irc, target) end
    bus.emit('chat.buffer', {net = net, target = target, opened = false})
end

--- Forget a buffer: part its channel if we are in it, and stop
--- monitoring its nick.
function M.close(net, target)
    local C = store.get(net)
    local key = store.fold(net, target)
    local irc = store.model(net)
    if irc and irc_model.get_channel(irc, target) then
        -- our PART coming back would reopen the buffer, and so would a
        -- message before it: H.PART drops the buffer again
        query(net, 'PART', target)
        C.closing[key] = true
    end
    monitor.release(net, 'chat', target)
    -- not rejoined on the next connection, even when we couldn't part
    intent.left(HUB.state.nets[net], irc, target)
    M.drop(net, key, target)
end

return M
