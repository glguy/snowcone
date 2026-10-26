-- Sending IRC commands (from ircc/utils/send.lua).
--
-- An argument is a string, or {content = string, secret = true} to keep it
-- out of logs. The masked message goes to the network's console log and
-- the `irc.sent` event; chat echo is the chat feature's business.

local bus        <const> = require 'hub.runtime.bus'
local clock      <const> = require 'hub.runtime.clock'
local dispatch   <const> = require 'hub.runtime.dispatch'
local resources  <const> = require 'hub.runtime.resources'
local OrderedMap <const> = require 'hub.lib.OrderedMap'

local M = {}

M.console_all_size = 2000

function M.init_state(S)
    -- every network's traffic, interleaved: {net = id, msg = msg, time, timestamp}
    S.console_all = S.console_all or OrderedMap.new(M.console_all_size)
end

--- Record a message, sent or received, in its network's console and in the
--- all-networks console.
function M.record(rec, msg)
    OrderedMap.insert(rec.console, true, msg)
    OrderedMap.insert(HUB.state.console_all, nil, {
        net = rec.id,
        msg = msg,
        time = msg.time,
        timestamp = msg.timestamp,
    })
end

--- Build the wire form of a command and its masked message record.
---@return string raw line with CRLF
---@return table message as recorded
function M.build(cmd, ...)
    local msg = {
        tags = {},
        command = cmd,
        source = '>>>',
        timestamp = clock.now(),
        time = os.date '!%H:%M:%S',
    }

    local parts = {cmd}
    local n = select('#', ...)

    for i = 1, n do
        local v = select(i, ...)
        local part
        if type(v) == 'table' then
            part = tostring(v.content)
            if v.secret then
                msg[i] = '\x0304*'
            else
                msg[i] = part
            end
        else
            part = tostring(v)
            msg[i] = part
        end

        -- Only the last argument can be empty, start with : or hold a space
        if string.find(part, '[\x00\r\n]') then
            error('prohibited character in command argument', 0)
        elseif not string.find(part, '^[^ :][^ ]*$') then
            if i ~= n then
                error('malformed internal command argument', 3)
            end
            parts[i + 1] = ':' .. part
        else
            parts[i + 1] = part
        end
    end

    return table.concat(parts, ' ') .. '\r\n', msg
end

--- Send a command on a network's connection.
---@param net string network id
---@param cmd string
function M.send(net, cmd, ...)
    local rec = HUB.state.nets[net]
    local conn = rec and rec.conn and resources.get(rec.conn)
    if not conn then
        error('network not connected: ' .. tostring(net), 0)
    end

    local raw, msg = M.build(cmd, ...)
    local linelen = rec.irc and rec.irc.linelen or 512
    if #raw > linelen then
        error('message too long: ' .. #raw, 0)
    end

    conn:send(raw)
    M.record(rec, msg)
    bus.emit('irc.sent', {net = net, msg = msg})
    dispatch.dirty()
end

--- Send text as a line exactly as given, without checking it as a
--- command. It still may not contain CR, LF or NUL.
function M.raw(net, text)
    local rec = HUB.state.nets[net]
    local conn = rec and rec.conn and resources.get(rec.conn)
    if not conn then
        error('network not connected: ' .. tostring(net), 0)
    end
    if text:find '[\x00\r\n]' then
        error('prohibited character in raw line', 0)
    end
    conn:send(text .. '\r\n')
    local msg = {
        tags = {},
        command = 'RAW',
        source = '>>>',
        timestamp = clock.now(),
        time = os.date '!%H:%M:%S',
        text,
    }
    M.record(rec, msg)
    dispatch.dirty()
end

M.routes = {
    ['net.send'] = M.send,
}

return M
