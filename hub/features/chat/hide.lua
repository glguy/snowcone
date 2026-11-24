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
-- M.check checks the rules as the configuration loads.

local channel_errors <const> = require 'hub.features.chat.channel_errors'
local irc_model      <const> = require 'hub.net.irc'
local luapattern     <const> = require 'hub.lib.luapattern'
local message_text   <const> = require 'hub.lib.message_text'
local regex          <const> = require 'hub.lib.regex'
local store          <const> = require 'hub.features.chat.store'

local M = {}

--- A configured hide rule ([[networks.hide]]), as M.check leaves
--- it: every matching field a list, any of whose entries match.
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

-- The commands chat places in a buffer, as a hide rule names them:
-- numerics by their digits
local buffer_commands <const> = {
    PRIVMSG = true, NOTICE = true, WALLOPS = true, OPERWALL = true,
    JOIN = true, PART = true, KICK = true, TOPIC = true, MODE = true,
    QUIT = true, NICK = true, ACCOUNT = true, CHGHOST = true,
}
for numeric in pairs(channel_errors) do
    buffer_commands[tostring(numeric)] = true
end

-- The matching fields of a hide rule
local hide_fields <const> = {'buffer', 'nick', 'account', 'command', 'pattern', 'regex'}

-- What a nick or account can't hold: a rule's are matched exactly, so
-- one with these was meant as a mask or a glob, and never matches
local not_in_name <const> = '[!@*?, ]'

--- Check a network's hide rules, as its configuration loads. Each rule's
--- matching fields become lists. A rule must match on something, since it
--- would otherwise hide everything, and nothing in it may make it never
--- match: an empty list, a command no buffer holds, a nick or account no
--- one can have, or text to match with commands that have none. It takes
--- a pattern or a regex, not both, and those must compile.
---@param net table the network's configuration
function M.check(net)
    for n, rule in ipairs(net.hide or {}) do
        local where = string.format('networks.%s.hide.%d', net.id, n)
        local function fail(fmt, ...)
            error(where .. string.format(fmt, ...), 0)
        end
        local any = false
        for _, field in ipairs(hide_fields) do
            if type(rule[field]) == 'string' then rule[field] = {rule[field]} end
            if rule[field] then
                any = true
                if #rule[field] == 0 then fail('.%s: an empty list matches nothing', field) end
            end
        end
        if not any then
            fail ': matches every message; give it buffer, nick, account, command, pattern or regex'
        end
        if rule.pattern and rule.regex then fail ': a pattern or a regex, not both' end
        for _, field in ipairs {'nick', 'account'} do
            for i, name in ipairs(rule[field] or {}) do
                if name:find(not_in_name) then
                    fail('.%s.%d: %s is matched exactly, and no %s holds !, @, *, ?, a comma or a space',
                        field, i, name, field)
                end
            end
        end
        local has_text = false
        for i, command in ipairs(rule.command or {}) do
            if not buffer_commands[command] then
                fail('.command.%d: no buffer holds %s', i, command)
            end
            if command == 'PRIVMSG' or command == 'NOTICE' then has_text = true end
        end
        if rule.command and (rule.pattern or rule.regex) and not has_text then
            fail ': a pattern or regex matches only PRIVMSG and NOTICE, which command leaves out'
        end
        for i, pattern in ipairs(rule.pattern or {}) do
            local err = luapattern.check(pattern)
            if err then fail('.pattern.%d: %s', i, err) end
        end
        for i, source in ipairs(rule.regex or {}) do
            local err = regex.check(source)
            if err then fail('.regex.%d: %s', i, err) end
        end
    end
    net.hide = net.hide or {}
end

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
local function any_name(net, names, name)
    if not name then return false end
    local key = store.fold(net, name)
    for _, other in ipairs(names) do
        if store.fold(net, other) == key then return true end
    end
    return false
end

local function matches(net, rule, target, msg)
    if rule.buffer and not any_name(net, rule.buffer, target) then return false end
    if rule.nick and not any_name(net, rule.nick, msg.nick) then return false end
    if rule.account and not any_name(net, rule.account, msg.tags and msg.tags.account) then
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
local function first_rule(net, target, msg)
    local rec = HUB.state.nets[net]
    if ours(rec and rec.irc, msg) then return nil, 'ours' end
    for i, rule in ipairs(rec and rec.cfg.hide or {}) do
        if matches(net, rule, target, msg) then return rule, i end
    end
    return nil
end

--- Whether chat discards a message bound for the buffer named `target`,
--- which it then neither opens nor adds to.
---@param net string
---@param target string
---@param msg hub.Message
---@return boolean
function M.discards(net, target, msg)
    local rule = first_rule(net, target, msg)
    return rule ~= nil and rule.action == 'discard'
end

--- Classify a message placed in a buffer, unless it already was there.
--- A discarding rule hides what reaches a buffer all the same, as a
--- message can when its buffer was renamed since chat asked.
---@param net string
---@param buffer hub.ChatBuffer
---@param msg hub.Message
function M.classify(net, buffer, msg)
    local decided = buffer.hide
    if not decided then
        decided = setmetatable({}, {__mode = 'k'})
        buffer.hide = decided
    end
    if decided[msg] ~= nil then return end
    local rule, i = first_rule(net, buffer.name, msg)
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
