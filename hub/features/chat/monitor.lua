-- MONITOR for chat's private buffers: each watches its nick's presence
-- while it is open, from when it opens or after registration, by its
-- current name across nick changes, until it closes. A nick the network
-- is waiting to reclaim (irc.recover_nick) keeps its MONITOR when its
-- buffer closes, since reclaiming it needs one. Server and channel
-- buffers watch nothing.
--
-- The functions take chat (features/chat), which requires this module.

local common    <const> = require 'hub.features.common'
local irc_model <const> = require 'hub.net.irc'

local M = {}

local query <const> = common.sender 'chat'

-- Nicks per MONITOR + line are joined until the list passes this many
-- bytes, leaving room for the command in a 512-byte line
local line_budget <const> = 400

-- Whether a buffer of this name watches its nick
local function watches(chat, net, irc, name)
    return not irc_model.is_channel_name(irc, name) and not chat.is_server(net, name)
end

--- Watch a buffer's nick, when it is a private buffer and we are
--- connected to a server with MONITOR.
---@param chat hub.ChatLookup
---@param net string
---@param target string
function M.watch(chat, net, target)
    local rec = HUB.state.nets[net]
    local irc = rec and rec.irc
    if irc and rec.phase == 'connected' and irc_model.has_monitor(irc)
    and watches(chat, net, irc, target)
    and not irc_model.get_monitor(irc, target) then
        query(net, 'MONITOR', '+', target)
    end
end

--- Stop watching a nick, unless it is the nick the network is waiting to
--- reclaim.
---@param net string
---@param irc hub.Irc
---@param target string
function M.unwatch(net, irc, target)
    if not irc_model.get_monitor(irc, target) then return end
    local wanted = irc.recover_nick
    if wanted and irc_model.fold(irc, wanted) == irc_model.fold(irc, target) then return end
    query(net, 'MONITOR', '-', target)
    irc_model.del_monitor(irc, target)
end

--- After registration: watch the nicks of all the private buffers, in as
--- few lines as fit.
---@param chat hub.ChatLookup
---@param net string
---@param irc hub.Irc
function M.after_registration(chat, net, irc)
    if not irc_model.has_monitor(irc) then return end
    local nicks, size = {}, 0
    for _, buffer in pairs(chat.get(net).buffers) do
        if watches(chat, net, irc, buffer.name) then
            table.insert(nicks, buffer.name)
            size = size + #buffer.name + 1
            if size > line_budget then
                query(net, 'MONITOR', '+', table.concat(nicks, ','))
                nicks, size = {}, 0
            end
        end
    end
    if #nicks > 0 then
        query(net, 'MONITOR', '+', table.concat(nicks, ','))
    end
end

return M
