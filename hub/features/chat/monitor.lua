-- MONITOR for chat's private buffers: each watches its nick's presence
-- while it is open, from when it opens or after registration, by its
-- current name across nick changes, until it closes. A nick the network
-- is waiting to reclaim (irc.recover_nick) keeps its MONITOR when its
-- buffer closes, since reclaiming it needs one. Server and channel
-- buffers watch nothing.
--
-- The model (net/irc.lua) knows a nick is monitored only from the reply
-- to MONITOR +. A buffer that closes before that reply can't unwatch its
-- nick yet: a - sent then would be followed by the reply, which would put
-- the nick back in the model. So the nicks we asked for and have heard
-- no reply about are kept in C.monitoring (hub.ChatState), and the reply
-- unwatches one whose buffer has gone meanwhile.
--
-- The functions take chat (features/chat), which requires this module.

local common    <const> = require 'hub.features.common'
local irc_model <const> = require 'hub.net.irc'
local N         <const> = require 'hub.lib.numerics'

local M = {}

local query <const> = common.sender 'chat'

-- Nicks per MONITOR + line are joined until the list passes this many
-- bytes, leaving room for the command in a 512-byte line
local line_budget <const> = 400

-- Whether a buffer of this name watches its nick
local function watches(chat, net, irc, name)
    return not irc_model.is_channel_name(irc, name) and not chat.is_server(net, name)
end

-- The nicks asked for with no reply yet, by folded nick
local function monitoring(chat, net)
    local C = chat.get(net)
    C.monitoring = C.monitoring or {}
    return C.monitoring
end

-- Ask to watch nicks, in as few lines as fit
local function ask(chat, net, irc, nicks)
    local asked = monitoring(chat, net)
    local line, size = {}, 0
    for _, nick in ipairs(nicks) do
        asked[irc_model.fold(irc, nick)] = true
        table.insert(line, nick)
        size = size + #nick + 1
        if size > line_budget then
            query(net, 'MONITOR', '+', table.concat(line, ','))
            line, size = {}, 0
        end
    end
    if #line > 0 then
        query(net, 'MONITOR', '+', table.concat(line, ','))
    end
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
    and not irc_model.get_monitor(irc, target)
    and not monitoring(chat, net)[irc_model.fold(irc, target)] then
        ask(chat, net, irc, {target})
    end
end

--- Stop watching a nick, unless it is the nick the network is waiting to
--- reclaim. One whose MONITOR + has had no reply yet is left to the
--- reply (M.on_reply).
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

--- After registration: watch the nicks of all the private buffers.
---@param chat hub.ChatLookup
---@param net string
---@param irc hub.Irc
function M.after_registration(chat, net, irc)
    if not irc_model.has_monitor(irc) then return end
    local nicks = {}
    for _, buffer in pairs(chat.get(net).buffers) do
        if watches(chat, net, irc, buffer.name) then
            table.insert(nicks, buffer.name)
        end
    end
    ask(chat, net, irc, nicks)
end

-- The nicks of a MONITOR reply's list: nick[!user@host],...
local function each_nick(list)
    return (list or ''):gmatch '([^!,]+)[^,]*,?'
end

--- A reply to MONITOR + (730, 731, or 734 for a full list), after the
--- model has followed it: a nick we asked for is answered, and one whose
--- buffer has closed since is unwatched now.
---@param chat hub.ChatLookup
---@param net string
---@param irc hub.Irc
---@param msg hub.Message
function M.on_reply(chat, net, irc, msg)
    local asked = monitoring(chat, net)
    local list = msg.command == N.ERR_MONLISTFULL and msg[3] or msg[2]
    for nick in each_nick(list) do
        local key = irc_model.fold(irc, nick)
        if asked[key] then
            asked[key] = nil
            if not chat.buffer(net, nick) then
                M.unwatch(net, irc, nick)
            end
        end
    end
end

--- Replies are of the connection.
---@param C hub.ChatState
function M.reset(C)
    C.monitoring = nil
end

return M
