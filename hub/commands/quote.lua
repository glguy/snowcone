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
---@field state 'waiting'|'done'|'timeout'
---@field messages hub.Message[] the labeled reply: a batch's messages, one
--- message, or an ACK

-- How long a /quote waits for its labeled reply
local quote_timeout <const> = 30000

--- Send a /quote line labeled, and fill in its reply.
---@param net string
---@param msg hub.Message parsed from the command line, without a label
function M.labeled(net, msg)
    local label = send.send_labeled(net, msg.tags, msg.command, table.unpack(msg))
    if not label then return end
    local parts = {tostring(msg.command)}
    for i, arg in ipairs(msg) do
        parts[i + 1] = (i == #msg and (arg == '' or arg:find '^:' or arg:find ' ')) and ':' .. arg or arg
    end
    ---@type hub.QuoteReply
    local reply = {line = table.concat(parts, ' '), state = 'waiting', messages = {}}
    bus.emit('quote.sent', {net = net, reply = reply})

    task.spawn('quote', {net = net, owner = 'commands'}, function(t)
        local messages = t:wait_reply(label, quote_timeout)
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
end

return M
