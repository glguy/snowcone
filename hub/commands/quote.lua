-- /quote with labeled-response: the line goes out labeled, its reply is
-- emitted at once (quote.sent) for the UI to show, and a task fills it in
-- when the server answers, or gives up.

local bus      <const> = require 'hub.runtime.bus'
local dispatch <const> = require 'hub.runtime.dispatch'
local log      <const> = require 'hub.runtime.log'
local send     <const> = require 'hub.net.send'
local task     <const> = require 'hub.runtime.task'

local M = {}

--- The reply to a /quote, with labeled-response: emitted (quote.sent)
--- when the line goes, waiting, and filled in place when the reply comes.
---@class hub.QuoteReply
---@field line string the command as sent, without tags
---@field state 'waiting'|'done'|'timeout'|'dropped' dropped when the
--- connection ended first
---@field messages hub.Message[] the labeled reply: a batch's messages, one
--- message, or an ACK

-- How long a /quote waits for its labeled reply
local quote_timeout <const> = 30000

-- Replies still waiting, by task id; a reload forgets them, leaving them
-- waiting
local waiting = {}

-- Services commands whose arguments hold a password
local services_secret <const> = {
    IDENTIFY = true, ID = true, REGISTER = true, GHOST = true, RECOVER = true,
    REGAIN = true, RELEASE = true, LOGIN = true, SETPASS = true, SET = true,
}

-- NickServ, nickserv@services.example, ...
local function is_services(target)
    return (target:match '^[^@]*'):lower():find 'serv$' ~= nil
end

local function services_command(text)
    local word = text:match '^:?(%S+)'
    return word and services_secret[word:upper()]
end

-- Which arguments of a typed command are secrets, by index
local function secret_indexes(msg)
    local command = tostring(msg.command):upper()
    local n = #msg
    if command == 'OPER' then
        return {[2] = true}
    elseif command == 'PASS' then
        return {[1] = true}
    elseif command == 'AUTHENTICATE' then
        -- everything but a continuation or an abort
        return {[1] = msg[1] ~= '+' and msg[1] ~= '*'}
    elseif (command == 'PRIVMSG' or command == 'NOTICE') and n == 2
        and is_services(msg[1]) and services_command(msg[2]) then
        return {[2] = true}
    elseif (command == 'NS' or command == 'NICKSERV') and n >= 1 and services_command(msg[1]) then
        local all = {}
        for i = 1, n do all[i] = true end
        return all
    end
    return {}
end

--- The arguments of a typed command, with any password among them marked
--- secret so it stays out of the console, the log and events.
---@param msg snowcone.Message
---@return hub.SendArg[] args
---@return string[] shown the arguments as shown, secrets as *
function M.arguments(msg)
    local secret = secret_indexes(msg)
    local args, shown = {}, {}
    for i, arg in ipairs(msg) do
        if secret[i] then
            args[i] = {content = arg, secret = true}
            shown[i] = '*'
        else
            args[i] = arg
            shown[i] = arg
        end
    end
    return args, shown
end

--- Send a /quote line labeled, and fill in its reply.
---@param net string
---@param msg snowcone.Message parsed from the command line, without a label
function M.labeled(net, msg)
    local args, shown = M.arguments(msg)
    local label = send.send_labeled(net, msg.tags, msg.command, table.unpack(args))
    if not label then return end
    local parts = {tostring(msg.command)}
    for i, arg in ipairs(shown) do
        parts[i + 1] = (i == #shown and (arg == '' or arg:find '^:' or arg:find ' ')) and ':' .. arg or arg
    end
    ---@type hub.QuoteReply
    local reply = {line = table.concat(parts, ' '), state = 'waiting', messages = {}}
    bus.emit('quote.sent', {net = net, reply = reply})

    local t = task.spawn('quote', {net = net, owner = 'commands'}, function(t)
        local messages = t:wait_reply(label, quote_timeout)
        waiting[t.id] = nil
        local detail = {kind = 'reply', data = reply}
        if messages == nil then
            reply.state = 'timeout'
            log.add_detail(t.net, 'quote', detail, '%s: no reply', reply.line)
        else
            reply.state = 'done'
            reply.messages = messages
            local summary
            if #messages == 1 and messages[1].command == 'ACK' then
                summary = 'acknowledged'
            elseif #messages == 1 then
                summary = '1 reply'
            else
                summary = #messages .. ' replies'
            end
            log.add_detail(t.net, 'quote', detail, '%s: %s', reply.line, summary)
        end
        dispatch.dirty()
    end)
    if HUB.tasks[t.id] then
        waiting[t.id] = reply
    end
end

M.subscribe = function(sub)
    -- the connection ended before the reply came
    sub.on('task.canceled', function(ev)
        local reply = waiting[ev.task]
        if not reply then return end
        waiting[ev.task] = nil
        reply.state = 'dropped'
        log.add_detail(ev.net, 'quote', {kind = 'reply', data = reply}, '%s: dropped with the connection',
            reply.line)
    end)
end

return M
