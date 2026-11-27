-- What chat asks of the server about channels: a channel's modes, topic
-- and list modes.
--
-- A channel we aren't in gets a snapshot (net/irc.lua observe_channel) to
-- take the replies, kept as long as its buffer, and is asked again after
-- each change we make there, since nothing tells us of changes in a
-- channel we aren't in. The replies update the snapshot or the joined
-- channel (net/handlers.lua).

local common     <const> = require 'hub.features.common'
local irc_model  <const> = require 'hub.net.irc'
local opening    <const> = require 'hub.features.chat.opening'

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

return M
