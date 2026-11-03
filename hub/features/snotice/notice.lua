-- Which messages are server notices on a network, and their parse, by
-- the network's ircd (net/ircd.lua). The snotice feature records the
-- answer on each message as it arrives (msg.snote), so the console and the
-- message detail show it as it was then, whatever our nick is now.
--
-- Solanum sends a notice to * with a header, and its answer to our ban or
-- unban to our nick without one. OFTC hybrid sends it to the
-- oper's nick, with the header when one server tells its own opers and
-- without it when the notice is the network's (a connection, an exit, a
-- kill), from the server it happened on.

local irc_model     <const> = require 'hub.net.irc'
local ircd          <const> = require 'hub.net.ircd'
local parse_hybrid  <const> = require 'hub.features.snotice.parse_hybrid'
local parse_solanum <const> = require 'hub.features.snotice.parse_solanum'

local M = {}

local header <const> = '*** Notice -- '

local parsers <const> = {
    [ircd.SOLANUM] = parse_solanum,
    [ircd.HYBRID] = parse_hybrid,
}

--- The parser of a network's server notices: parse(server, text).
---@param net string|nil
---@return fun(server: string, text: string): table|nil
function M.parser(net)
    return parsers[ircd.of(net)]
end

-- A NOTICE from a server (no ! or @ in the source), one argument after
-- the target
local function from_server(msg)
    local source = msg.source
    return msg.command == 'NOTICE' and #msg == 2
        and source ~= nil and not source:find '[!@]'
end

local function to_me(net, target)
    local rec = net and HUB.state.nets[net]
    local irc = rec and rec.irc
    return irc ~= nil and irc_model.is_me(irc, target)
end

-- The text of a server notice, without its header, or nil
local function recognize(net, msg)
    if not from_server(msg) then return nil end
    local target, body = msg[1], msg[2]
    local headed = body:sub(1, #header) == header
    if ircd.hybrid(net) then
        if not to_me(net, target) then return nil end
        if headed then return body:sub(#header + 1) end
        -- the network's notices have no header; a parse tells them from
        -- the server's other notices to us
        if parse_hybrid(msg.source, body) then return body end
    elseif target == '*' then
        if headed then return body:sub(#header + 1) end
    elseif not headed and to_me(net, target) and parse_solanum(msg.source, body) then
        -- the server's answer to our ban or unban
        return body
    end
end

--- Record on a message whether it is a server notice: msg.snote is its
--- text, or false. Returns the text.
---@param net string|nil
---@param msg hub.Message
---@return string|nil
function M.record(net, msg)
    local text = recognize(net, msg)
    msg.snote = text or false
    return text
end

--- The text of a server notice, without its header, or nil: as recorded
--- when it arrived, else as it would be recognized now.
---@param net string|nil
---@param msg hub.Message
---@return string|nil
function M.text(net, msg)
    local recorded = msg.snote
    if recorded ~= nil then return recorded or nil end
    return recognize(net, msg)
end

--- A message's server notice record, without the time, or nil.
---@param net string|nil
---@param msg hub.Message
---@return table|nil
function M.parse(net, msg)
    local text = M.text(net, msg)
    return text and M.parser(net)(msg.source, text)
end

return M
