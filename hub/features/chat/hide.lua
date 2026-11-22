-- Hide rules ([[networks.hide]]): which messages the buffer view leaves
-- out until Meta-H shows them in their buffer, and which chat discards,
-- never placing them in a buffer (nor opening one for them), from chat
-- history too. The console still shows what is discarded.
--
-- A message is classified once, as it is placed in a buffer, and the
-- result is kept with the buffer, since a QUIT or NICK is the same
-- message in every buffer it reaches and a rule naming a buffer can
-- hide it in one and not another. A reload changes how later messages
-- are classified, not the ones already kept.
--
-- The configured rules are tried in order and the first that matches
-- decides; then the built-in ones, which hide comings, goings and
-- identity changes. Our own messages match no rule.
--
-- The functions take chat (features/chat), which requires this module.
-- runtime/config.lua checks the rules as the configuration loads.

local irc_model    <const> = require 'hub.net.irc'
local message_text <const> = require 'hub.lib.message_text'
local regex        <const> = require 'hub.lib.regex'

local M = {}

--- A configured hide rule ([[networks.hide]]), as runtime/config.lua
--- leaves it: every matching field a list, any of whose entries match.
---@class hub.HideRule
---@field buffer string[]|nil
---@field nick string[]|nil
---@field account string[]|nil
---@field command string[]|nil
---@field pattern string[]|nil Lua patterns
---@field regex string[]|nil PCRE2 regular expressions
---@field action 'hide'|'show'|'discard'|nil hide when nil

--- How a message was classified in a buffer: whether it is hidden, and
--- the rule that decided, by its position in [[networks.hide]] or
--- 'built-in'.
---@class hub.HideDecision
---@field hidden boolean
---@field rule integer|'built-in'

-- Commands the built-in rules hide: comings, goings and identity changes
M.presence = {
    JOIN = true,
    PART = true,
    QUIT = true,
    NICK = true,
    ACCOUNT = true,
    CHGHOST = true,
}

local built_in <const> = {hidden = true, rule = 'built-in'}

-- Whether a name is any of the names, as the network folds them
local function any_name(chat, net, names, name)
    if not name then return false end
    local key = chat.fold(net, name)
    for _, other in ipairs(names) do
        if chat.fold(net, other) == key then return true end
    end
    return false
end

local function matches(chat, net, rule, target, msg)
    if rule.buffer and not any_name(chat, net, rule.buffer, target) then return false end
    if rule.nick and not any_name(chat, net, rule.nick, msg.nick) then return false end
    if rule.account and not any_name(chat, net, rule.account, msg.tags and msg.tags.account) then
        return false
    end
    if rule.command then
        local found = false
        local name = tostring(msg.command)
        for _, command in ipairs(rule.command) do
            if command == name then found = true end
        end
        if not found then return false end
    end
    if rule.pattern or rule.regex then
        -- a PRIVMSG's or NOTICE's, without formatting or action framing
        local text = message_text.of(msg)
        if not text then return false end
        local found = false
        for _, pattern in ipairs(rule.pattern or {}) do
            local ok, at = pcall(string.find, text, pattern)
            if ok and at then found = true end
        end
        for _, source in ipairs(rule.regex or {}) do
            if regex.find(source, text) then found = true end
        end
        if not found then return false end
    end
    return true
end

-- Whether a message is ours: as sent, or echoed or relayed back. Our
-- NICK reaches chat once the model has taken the new nick, so it is ours
-- when that new nick is.
local function ours(irc, msg)
    if msg.source == '>>>' then return true end
    if irc == nil then return false end
    if msg.nick ~= nil and irc_model.is_me(irc, msg.nick) then return true end
    return msg.command == 'NICK' and msg[1] ~= nil and irc_model.is_me(irc, msg[1])
end

-- The first configured rule matching someone else's message for a
-- buffer named `target`, and its position. Our own messages match none.
local function first_rule(chat, net, target, msg)
    local rec = HUB.state.nets[net]
    if ours(rec and rec.irc, msg) then return nil, 'ours' end
    for i, rule in ipairs(rec and rec.cfg.hide or {}) do
        if matches(chat, net, rule, target, msg) then return rule, i end
    end
    return nil
end

--- Whether chat discards a message bound for the buffer named `target`,
--- which it then neither opens nor adds to.
---@param chat hub.ChatLookup
---@param net string
---@param target string
---@param msg hub.Message
---@return boolean
function M.discards(chat, net, target, msg)
    local rule = first_rule(chat, net, target, msg)
    return rule ~= nil and rule.action == 'discard'
end

--- Classify a message placed in a buffer, unless it already was there.
--- A discarding rule hides what reaches a buffer all the same, as a
--- message can when its buffer was renamed since chat asked.
---@param chat hub.ChatLookup
---@param net string
---@param buffer hub.ChatBuffer
---@param msg hub.Message
function M.classify(chat, net, buffer, msg)
    local decided = buffer.hide
    if not decided then
        decided = setmetatable({}, {__mode = 'k'})
        buffer.hide = decided
    end
    if decided[msg] ~= nil then return end
    local rule, i = first_rule(chat, net, buffer.name, msg)
    ---@type hub.HideDecision|false
    local decision = false
    if rule then
        ---@cast i integer
        decision = {hidden = rule.action ~= 'show', rule = i}
    elseif i ~= 'ours' and M.presence[msg.command] then
        decision = built_in
    end
    decided[msg] = decision
end

--- How a message was classified in a buffer, or nil when no rule
--- decided.
---@param buffer hub.ChatBuffer
---@param msg hub.Message
---@return hub.HideDecision|nil
function M.decision(buffer, msg)
    return buffer.hide and buffer.hide[msg] or nil
end

--- Whether a message is hidden in a buffer.
---@param buffer hub.ChatBuffer
---@param msg hub.Message
---@return boolean
function M.hidden(buffer, msg)
    local decision = M.decision(buffer, msg)
    return decision ~= nil and decision.hidden
end

return M
