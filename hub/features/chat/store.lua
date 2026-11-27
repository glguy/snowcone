-- Chat's state: its buffers by network and folded target, and looking
-- them up. Every other part of chat builds on this one.

local casemap    <const> = require 'hub.lib.casemap'
local common     <const> = require 'hub.features.common'
local irc_model  <const> = require 'hub.net.irc'

local M = {}

M.name = 'chat'
M.buffer_size = 1000

--- A network's chat, state.features.chat[net].
---@class hub.ChatState
---@field buffers table<string, hub.ChatBuffer> by folded target
---@field pending table<string, table<string, {msg: hub.Message, buffer: hub.ChatBuffer|nil}>>
--- by label, then by folded target; for the current connection
---@field closing table<string, true> channels /close parted, by folded name;
--- for the current connection
---@field composing hub.ChatComposing|nil what we are writing and where
---@field history_bucket number|nil pacing of new buffers' history requests (lib/ratelimit)
---@field ctcp_bucket number|nil pacing of CTCP replies to non-staff (lib/ratelimit)
---@field casemapping string|nil what the keys are folded with: the
--- network's, as last announced; rfc1459 before any

---@return hub.ChatState
local function new_state()
    return {buffers = {}, pending = {}, closing = {}}
end

---@param net string
---@return hub.ChatState
function M.get(net)
    local C = common.net_state(M.name, net, new_state)
    -- added after state from earlier code
    C.pending = C.pending or {}
    C.closing = C.closing or {}
    return C
end

---@class hub.ChatBuffer
---@field name string the target, as last seen
---@field messages hub.OrderedMap keyed by msgid, when there is one
---@field activity integer messages since it was last seen
---@field mention boolean
---@field seen hub.Message|false|nil the newest message when it was last
--- seen; false when it was seen empty, nil when never
---@field typing table<string, hub.ChatTyping>|nil by folded nick; nil in
--- buffers from before typing was tracked (chat/typing.lua)
---@field hide table<hub.Message, hub.HideDecision|false>|nil how each
--- message was classified (chat/hide.lua), weak-keyed; nil until one is

--- Whether a network has chat.
---@param net string
---@return boolean
function M.enabled(net)
    return common.enabled(net, M.name)
end

--- The protocol model of a network's connection, if any.
---@param net string
---@return hub.Irc|nil
function M.model(net)
    local rec = HUB.state.nets[net]
    return rec and rec.irc
end

--- A buffer named for a server, which sends WALLOPS and messages to
--- broadcast masks; such a buffer has no history, typing or MONITOR. A
--- buffer from before, named *wallops, is one too.
---@param net string
---@param name string
---@return boolean
function M.is_server(net, name)
    if name:sub(1, 1) == '*' then return true end
    local rec = HUB.state.nets[net]
    local irc = rec and rec.irc
    local channel = irc and irc_model.is_channel_name(irc, name) or not irc and name:find '^[#&]'
    return not channel and name:find('.', 1, true) ~= nil
end

--- Fold a target with the network's casemapping: the one the server
--- announced, or the one last announced while it hasn't (between
--- connections, and while registering), so keys stay the same.
function M.fold(net, target)
    local irc = M.model(net)
    if irc and irc.isupport.CASEMAPPING ~= nil then
        return irc_model.fold(irc, target)
    end
    local C = common.get_state(M.name, net)
    return casemap.fold(C and C.casemapping or 'rfc1459', target)
end

--- A test for names that start with seed, as the network folds them.
---@param net string
---@param seed string
---@return fun(name: string): boolean
function M.name_matcher(net, seed)
    local prefix = M.fold(net, seed)
    return function(name)
        return M.fold(net, name):sub(1, #prefix) == prefix
    end
end

--- A buffer, if it exists.
function M.buffer(net, target)
    return M.get(net).buffers[M.fold(net, target)]
end

return M
