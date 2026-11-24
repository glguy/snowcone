-- What chat asks of the server about channels: a channel's modes, topic
-- and list modes, and the channel list (LIST).
--
-- A channel we aren't in gets a snapshot (net/irc.lua observe_channel) to
-- take the replies, kept as long as its buffer, and is asked again after
-- each change we make there, since nothing tells us of changes in a
-- channel we aren't in. The replies update the snapshot or the joined
-- channel (net/handlers.lua).
--
-- The channel list holds the newest of the last LIST's replies, at most
-- store.list_size, in C.list, and C.list_count counts them all.

local common     <const> = require 'hub.features.common'
local irc_model  <const> = require 'hub.net.irc'
local N          <const> = require 'hub.lib.numerics'
local opening    <const> = require 'hub.features.chat.opening'
local OrderedMap <const> = require 'hub.lib.OrderedMap'
local send       <const> = require 'hub.net.send'
local store      <const> = require 'hub.features.chat.store'

local M = {}

local query <const> = common.sender 'chat'

local function model(net)
    local rec = HUB.state.nets[net]
    return rec and rec.irc
end

-- Ask again for all that a snapshot holds
local function refetch(net, channel)
    query(net, 'MODE', channel.name)
    query(net, 'TOPIC', channel.name)
    local lists = {}
    for mode in pairs(channel.list_modes) do table.insert(lists, mode) end
    table.sort(lists)
    for _, mode in ipairs(lists) do
        query(net, 'MODE', channel.name, '+' .. mode)
    end
end

-- Make sure a channel we aren't in has a snapshot, to take the replies to
-- what we ask, and the buffer that keeps it. Nil for a joined channel, or
-- with no registered connection.
local function observe(net, name)
    local irc = model(net)
    if not irc or HUB.state.nets[net].phase ~= 'connected' or irc_model.get_channel(irc, name) then
        return nil
    end
    opening.open(net, name)
    return irc_model.observe_channel(irc, name)
end

--- Ask for what a channel's information needs. For a joined channel, what
--- the server didn't send on join: its modes and creation time (MODE),
--- unless they are known. For another, a snapshot, in a buffer opened in
--- the background, and all that it holds, again.
---@param net string
---@param name string
function M.channel_info(net, name)
    local observed = observe(net, name)
    if observed then return refetch(net, observed) end
    local irc = model(net)
    local channel = irc and irc_model.get_channel(irc, name)
    if channel and not channel.modes then
        query(net, 'MODE', name)
    end
end

--- After a change we made in a channel we aren't in: no broadcast will
--- tell us of it, so a snapshot asks again.
---@param net string
---@param name string
function M.refetch_observed(net, name)
    local irc = model(net)
    local channel = irc and irc_model.observed_channel(irc, name)
    if channel then refetch(net, channel) end
end

--- Ask again for a channel's modes and creation time.
---@param net string
---@param name string
function M.refresh_modes(net, name)
    observe(net, name)
    query(net, 'MODE', name)
end

--- Ask again for a channel's topic.
---@param net string
---@param name string
function M.refresh_topic(net, name)
    observe(net, name)
    query(net, 'TOPIC', name)
end

--- Fetch a list mode of a channel, such as its bans (b) or quiets (q).
---@param net string
---@param name string
---@param mode string
function M.fetch_list(net, name, mode)
    observe(net, name)
    query(net, 'MODE', name, '+' .. mode)
end

--- Remove an entry from a list mode of a channel.
---@param net string
---@param name string
---@param mode string
---@param mask string
function M.unset_list(net, name, mode, mask)
    query(net, 'MODE', name, '-' .. mode, mask)
    M.refetch_observed(net, name)
end

-- The channel list (LIST) =============================================

--- Fetch the channel list, replacing the last one (C.list).
---@param net string
---@param arg string|nil the server's LIST argument, such as a mask
function M.list(net, arg)
    local C = store.get(net)
    OrderedMap.reset(C.list)
    C.list_count = 0
    C.listing = true
    if arg and arg ~= '' then
        send.send(net, 'LIST', arg)
    else
        send.send(net, 'LIST')
    end
end

--- Handlers of the replies to LIST, by command, for chat's own.
M.handlers = {}

-- "<client> <channel> <client count> :<topic>"
M.handlers[N.RPL_LIST] = function(net, msg)
    local C = store.get(net)
    if C.listing then
        -- the list keeps the newest list_size; how many came is shown
        C.list_count = (C.list_count or 0) + 1
        OrderedMap.insert(C.list, msg[2], {
            time = msg.time,
            timestamp = msg.timestamp,
            channel = msg[2],
            users = math.tointeger(msg[3]),
            topic = msg[4] or '',
        })
    end
end

M.handlers[N.RPL_LISTEND] = function(net)
    store.get(net).listing = nil
end

return M
