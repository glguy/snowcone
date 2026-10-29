-- Sending IRC commands.
--
-- An argument is a string, or {content = string, secret = true} to keep it
-- out of logs. Requests (t:request) carry a label tag when the network has
-- labeled-response; tags don't count against the line length. The masked message goes to the network's console log and
-- the `irc.sent` event; chat echo is the chat feature's business.
--
-- A network's `rate_limit` paces its lines (lib/ratelimit.lua). A line
-- that can't go yet waits in rec.sendq = {t, lines, timer}: t is the
-- bucket's time, lines the {raw, msg} entries in order, timer the resource
-- id of the pending drain. A queued line is recorded and reported at once,
-- with msg.delivery = {state = 'queued'}; the queue sets state to 'sent'
-- (and delay, in seconds) when it writes the line, or to 'dropped' when
-- the connection ends first. Copies of the message share that table. A
-- line written at once has no delivery field.

local bus        <const> = require 'hub.runtime.bus'
local clock      <const> = require 'hub.runtime.clock'
local dispatch   <const> = require 'hub.runtime.dispatch'
local log        <const> = require 'hub.runtime.log'
local resources  <const> = require 'hub.runtime.resources'
local timer      <const> = require 'hub.runtime.timer'
local OrderedMap <const> = require 'hub.lib.OrderedMap'
local ratelimit  <const> = require 'hub.lib.ratelimit'

local M = {}

---@alias hub.SendArg string|number|{content: string, secret: boolean|nil}

---@class hub.SendQueue
---@field t number the bucket's time
---@field lines {raw: string, msg: hub.Message}[] in order
---@field timer integer|nil resource id of the pending drain

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
---@param cmd string|integer
---@param ... hub.SendArg
---@return string raw line with CRLF
---@return hub.Message msg as recorded
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

local tag_escapes <const> = {
    [';'] = '\\:', [' '] = '\\s', ['\\'] = '\\\\', ['\r'] = '\\r', ['\n'] = '\\n',
}

--- The wire form of message tags, '@a=1;b=2 ', or '' without any.
---@param tags table<string, string>|nil
---@return string
function M.tag_prefix(tags)
    if tags == nil or next(tags) == nil then return '' end
    local keys = {}
    for k in pairs(tags) do table.insert(keys, k) end
    table.sort(keys)
    for i, k in ipairs(keys) do
        local v = tags[k]
        if v ~= '' then
            keys[i] = k .. '=' .. string.gsub(v, '[; \\\r\n]', tag_escapes)
        end
    end
    return '@' .. table.concat(keys, ';') .. ' '
end

-- The send queue ====================================================

-- The network's queue, created with a full burst when first needed
local function queue(rec)
    local q = rec.sendq
    if q == nil then
        q = {t = clock.now(), lines = {}}
        rec.sendq = q
    end
    return q
end

-- Seconds until the rate limit lets the next line go
local function wait(rec, q)
    local limit = rec.cfg.rate_limit
    if limit == nil then return 0 end
    return ratelimit.wait(q.t, clock.now(), limit.burst, limit.interval)
end

local function write(rec, q, conn, entry)
    local now = clock.now()
    local limit = rec.cfg.rate_limit
    if limit then
        q.t = ratelimit.take(q.t, now, limit.interval)
    end
    conn:send(entry.raw)
    local delivery = entry.msg.delivery
    if delivery then
        delivery.state = 'sent'
        delivery.delay = now - entry.msg.timestamp
    end
end

-- Write the lines the rate limit allows now, and start a timer for the
-- rest
local function drain(rec)
    local q = rec.sendq
    local conn = rec.conn and resources.get(rec.conn)
    if not (q and conn) then return end
    local lines = q.lines
    while lines[1] do
        local seconds = wait(rec, q)
        if seconds > 0 then
            if not q.timer then
                local ms = math.max(1, math.ceil(seconds * 1000))
                q.timer = timer.start('net', ms, 'net.send_drain', rec.id, rec.attempt)
            end
            return
        end
        write(rec, q, conn, table.remove(lines, 1))
        dispatch.dirty()
    end
end

-- Write a line, or queue it behind the others (in front of them when
-- first is true)
local function submit(rec, conn, raw, msg, first)
    local q = queue(rec)
    local entry = {raw = raw, msg = msg}
    if not q.lines[1] and wait(rec, q) == 0 then
        write(rec, q, conn, entry)
        return
    end
    msg.delivery = {state = 'queued'}
    table.insert(q.lines, first and 1 or #q.lines + 1, entry)
    drain(rec)
end

--- Drop the network's queued lines, marking them dropped, and its drain
--- timer.
---@param rec hub.Network
---@return integer # how many lines were dropped
function M.drop(rec)
    local q = rec.sendq
    if q == nil then return 0 end
    rec.sendq = nil
    if q.timer then
        timer.cancel(q.timer)
    end
    for _, entry in ipairs(q.lines) do
        entry.msg.delivery.state = 'dropped'
    end
    local n = #q.lines
    if n > 0 then
        log.add_net(rec.id, 'irc', 'dropped %d queued %s', n, n == 1 and 'line' or 'lines')
        dispatch.dirty()
    end
    return n
end

--- A line sent now would be written at once, not queued.
function M.ready(net)
    local rec = HUB.state.nets[net]
    if not (rec and rec.conn) then return false end
    local q = queue(rec)
    return not q.lines[1] and wait(rec, q) == 0
end

-- Sending ============================================================

local function connection(net)
    local rec = HUB.state.nets[net]
    local conn = rec and rec.conn and resources.get(rec.conn)
    if not conn then
        error('network not connected: ' .. tostring(net), 0)
    end
    return rec, conn
end

-- how: nil to wait in turn, 'first' to go ahead of the queue, 'last' to
-- drop the queue and write at once. Tags don't count against the line
-- length.
local function send(how, net, tags, cmd, ...)
    local rec, conn = connection(net)

    local raw, msg = M.build(cmd, ...)
    local linelen = rec.irc and rec.irc.linelen or 512
    if #raw > linelen then
        error('message too long: ' .. #raw, 0)
    end
    if tags then
        raw = M.tag_prefix(tags) .. raw
        for k, v in pairs(tags) do msg.tags[k] = v end
    end

    if how == 'last' then
        M.drop(rec)
        conn:send(raw)
    else
        submit(rec, conn, raw, msg, how == 'first')
    end
    M.record(rec, msg)
    bus.emit('irc.sent', {net = net, msg = msg})
    dispatch.dirty()
end

--- Send a command on a network's connection. It waits its turn when the
--- network's rate limit holds it back.
---@param net string network id
---@param cmd string|integer
---@param ... hub.SendArg
function M.send(net, cmd, ...)
    send(nil, net, nil, cmd, ...)
end

--- Send a command ahead of any queued lines, for replies that can't wait,
--- like PONG. It still counts against the rate limit.
function M.send_first(net, cmd, ...)
    send('first', net, nil, cmd, ...)
end

--- Drop the queued lines and send a command at once, outside the rate
--- limit: a last line, like QUIT.
function M.send_last(net, cmd, ...)
    send('last', net, nil, cmd, ...)
end

--- Send a command whose replies a task waits for (t:request). With
--- labeled-response it carries a label, unique on the connection, that
--- the reply will carry too.
---@param net string network id
---@param cmd string|integer
---@param ... hub.SendArg
---@return string|nil label nil when the network can't label replies
function M.send_request(net, cmd, ...)
    local rec = HUB.state.nets[net]
    local irc = rec and rec.irc
    if irc and irc.caps_enabled['labeled-response'] and irc.caps_enabled.batch then
        local n = (irc.label_next or 0) + 1
        local label = tostring(n)
        send(nil, net, {label = label}, cmd, ...)
        irc.label_next = n
        return label
    end
    send(nil, net, nil, cmd, ...)
end

--- Send text as a line exactly as given, without checking it as a
--- command. It still may not contain CR, LF or NUL.
function M.raw(net, text)
    local rec, conn = connection(net)
    if text:find '[\x00\r\n]' then
        error('prohibited character in raw line', 0)
    end
    local msg = {
        tags = {},
        command = 'RAW',
        source = '>>>',
        timestamp = clock.now(),
        time = os.date '!%H:%M:%S',
        text,
    }
    submit(rec, conn, text .. '\r\n', msg)
    M.record(rec, msg)
    dispatch.dirty()
end

M.routes = {
    ['net.send'] = M.send,
    ['net.send_request'] = M.send_request,
    ['net.send_drain'] = function(id, attempt)
        local rec = HUB.state.nets[id]
        if not (rec and rec.attempt == attempt and rec.sendq) then return end
        rec.sendq.timer = nil
        drain(rec)
    end,
}

return M
