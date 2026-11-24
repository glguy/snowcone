-- The nick we want, across connections (net/intent.lua), and whether the
-- connection is on it. Taking it back is net/reclaim.lua's.

local intent    <const> = require 'hub.net.intent'
local irc_model <const> = require 'hub.net.irc'
local reclaim   <const> = require 'hub.net.reclaim'
local send      <const> = require 'hub.net.send'

local M = {}

--- The nick we want: the last one given to /nick, or else the configured
--- one. A configured nick that changes replaces a /nick.
---@param rec hub.Network
---@return string
function M.wanted(rec)
    return intent.of(rec).nick or rec.cfg.identity.nick
end

--- Change our nick at the user's word: the nick given, as the server
--- takes it, becomes the wanted one, here and on later connections, and
--- is what reclaiming waits for if it is taken.
---@param net string
---@param nick string
function M.declare(net, nick)
    local rec = HUB.state.nets[net]
    local irc = rec.irc
    local wanted = irc and irc_model.cut_nick(irc, nick) or nick
    intent.of(rec).nick = wanted ~= rec.cfg.identity.nick and wanted or nil
    if irc then
        reclaim.stop(rec, irc)
    end
    send.send(net, 'NICK', nick)
end

--- Whether we are on the wanted nick, as the server takes it.
---@param rec hub.Network
---@param irc hub.Irc
---@return boolean
function M.on_wanted(rec, irc)
    return irc_model.is_me(irc, irc_model.cut_nick(irc, M.wanted(rec)))
end

--- Reclaim the wanted nick when we aren't on it.
---@param rec hub.Network
---@param irc hub.Irc
function M.want_back(rec, irc)
    if not M.on_wanted(rec, irc) then
        reclaim.start(rec, irc, M.wanted(rec))
    end
end

return M
