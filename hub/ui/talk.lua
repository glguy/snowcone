-- Talking: the buffer shown for each network, the STATUSMSG prefix its
-- lines go out with, and what of a line the server would relay.

local chat      <const> = require 'hub.features.chat'
local control   <const> = require 'hub.ui.control'
local dispatch  <const> = require 'hub.runtime.dispatch'
local irc_model <const> = require 'hub.net.irc'

local M = {}

--- The buffer shown for a network, by name.
function M.target(net)
    local vs = control.view_state 'buffer'
    return vs.targets and vs.targets[net]
end

--- Whether a word names someone where it would be sent on a network:
--- the buffer shown, or a member of it when it is a channel. Spell
--- checking leaves names alone.
---@param net string
---@return fun(word: string): boolean
function M.names_here(net)
    local rec = HUB.state.nets[net]
    local irc = rec and rec.irc
    local target = M.target(net)
    if not irc then return function() return false end end
    local folded = target and irc_model.fold(irc, target)
    local channel = target and irc_model.is_channel_name(irc, target)
        and irc_model.get_channel(irc, target)
    return function(word)
        if word == '' then return false end
        if folded and irc_model.fold(irc, word) == folded then return true end
        return channel and irc_model.get_member(irc, channel, word) ~= nil or false
    end
end

--- Show a buffer of a network, remembering the one shown before.
function M.set_target(net, target)
    local vs = control.view_state 'buffer'
    vs.targets = vs.targets or {}
    vs.previous = vs.previous or {}
    local current = vs.targets[net]
    if current ~= target then
        vs.previous[net] = current
        vs.targets[net] = target
        vs.scroll = 0
    end
    dispatch.dirty()
end

--- Follow a buffer's rename (chat.rename): the shown and previous buffers
--- that named it by its old name name it by its new one. Unlike a move to
--- another buffer, it changes nothing Meta-S goes back to.
---@param net string
---@param from string
---@param to string
function M.rename(net, from, to)
    local vs = control.view_state 'buffer'
    local key = chat.fold(net, from)
    for _, names in ipairs {vs.targets or {}, vs.previous or {}} do
        local name = names[net]
        if name and chat.fold(net, name) == key then names[net] = to end
    end
    dispatch.dirty()
end

--- The STATUSMSG prefix ('@' or '+') lines to a network's shown buffer
--- go out with, or nil. Each buffer keeps its own, so leaving one and
--- coming back doesn't drop its lines to the whole channel.
---@param net string
---@return string|nil
function M.statusmsg(net)
    local target = M.target(net)
    local vs = control.view_state 'buffer'
    local prefixes = target and vs.statusmsg and vs.statusmsg[net]
    return prefixes and prefixes[chat.fold(net, target)]
end

--- Input modes whose line goes to the shown buffer, and the command it
--- goes out as.
M.modes = {talk = 'PRIVMSG', quiet = 'PRIVMSG', action = 'PRIVMSG', notice = 'NOTICE'}

--- Where a line in a talk mode stops reaching others, when the server
--- relays it to the network's shown buffer: the bytes that do, whole
--- characters of them, and how far over the line is. Nothing when it all
--- fits, or there is nowhere to send it yet.
---@param net string
---@param mode string one of modes
---@param text string valid UTF-8, as the editor gives it
---@return integer|nil cut
---@return integer|nil over
function M.overflow(net, mode, text)
    local irc = HUB.state.nets[net].irc
    local target = M.target(net)
    if not (irc and target) then return end
    local room = irc_model.text_room(irc, M.modes[mode], (M.statusmsg(net) or '') .. target)
    if mode == 'action' then room = room - chat.action_overhead end
    room = math.max(room, 0)
    if #text <= room then return end
    local over = #text - room
    -- back to the start of a character the cut would break
    while text:byte(room + 1) & 0xC0 == 0x80 do room = room - 1 end
    return room, over
end

--- Set the STATUSMSG prefix of a network's buffer, by default the shown
--- one; nil sends to the whole target again.
---@param net string
---@param prefix string|nil
---@param target string|nil
function M.set_statusmsg(net, prefix, target)
    target = target or M.target(net)
    if not target then return end
    local vs = control.view_state 'buffer'
    vs.statusmsg = vs.statusmsg or {}
    vs.statusmsg[net] = vs.statusmsg[net] or {}
    vs.statusmsg[net][chat.fold(net, target)] = prefix
    dispatch.dirty()
end

return M
