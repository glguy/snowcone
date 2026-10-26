-- Connection manager: one record per network, any number connected at
-- once (design section 6.2).
--
-- state.nets[id] = {
--   id, cfg            network configuration (from state.config)
--   target             'connected' | 'idle' | 'removed'
--   phase              'idle' | 'resolving_secrets' | 'connecting'
--                      | 'registering' | 'connected' | 'closing'
--   attempt            increments per connect attempt
--   conn               resource id of the connection, nil when idle
--   since              clock when phase last changed
--   liveness           clock of the last inbound message
--   backoff            seconds, next reconnect delay before jitter
--   reconnect_timer    resource id while a reconnect is scheduled, due at
--                      reconnect_at
--   restart_pending    connection settings changed under a live connection;
--                      /reconnect applies them
--   lag                seconds, from the last PING we sent and its PONG
--   lag_token          the PING argument awaiting its PONG, lag_sent its time
--   irc                protocol model (net/irc.lua), nil when idle
--   fingerprint        of the current connection
--   console            OrderedMap of recent raw messages, both directions
-- }
--
-- Connection callbacks are trampolines bound to (id, attempt). Events from
-- any attempt but the current live one are dropped, so a connection that
-- closed and reconnected before its old events drained is safe.

local batch        <const> = require 'hub.net.batch'
local bus          <const> = require 'hub.runtime.bus'
local clock        <const> = require 'hub.runtime.clock'
local dispatch     <const> = require 'hub.runtime.dispatch'
local handlers     <const> = require 'hub.net.handlers'
local irc_model    <const> = require 'hub.net.irc'
local log          <const> = require 'hub.runtime.log'
local OrderedMap   <const> = require 'hub.lib.OrderedMap'
local registration <const> = require 'hub.net.registration'
local resources    <const> = require 'hub.runtime.resources'
local secrets      <const> = require 'hub.runtime.secrets'
local send         <const> = require 'hub.net.send'
local task         <const> = require 'hub.runtime.task'
local timer        <const> = require 'hub.runtime.timer'
local tablex       <const> = require 'pl.tablex'

local M = {}

M.console_size = 1000
M.ping_after = 30          -- seconds of silence before PING
M.timeout_after = 60       -- seconds of silence before closing
M.connect_timeout = 60     -- seconds to wait for CON
M.stable_after = 60        -- registered this long resets the backoff
M.lag_every = 60           -- seconds between lag measurements
M.quit_grace_ms = 5000     -- wait for the server to close after QUIT

function M.init_state(S)
    S.nets = S.nets or {}
end


local function nets()
    return HUB.state.nets
end

-- Drop a network's record once it is removed and idle
local function remove_record(id)
    nets()[id] = nil
    bus.emit('net.removed', {net = id})
end

local function get(id)
    local rec = nets()[id]
    if rec == nil then
        error('no such network: ' .. tostring(id), 3)
    end
    return rec
end

--- Ids of all networks: in configuration order, then any records the
--- configuration no longer lists (still closing), by id.
function M.ids()
    local ids, seen = {}, {}
    local cfg = HUB.state.config
    for _, net in ipairs(cfg and cfg.networks or {}) do
        if nets()[net.id] then
            table.insert(ids, net.id)
            seen[net.id] = true
        end
    end
    local rest = {}
    for id in pairs(nets()) do
        if not seen[id] then table.insert(rest, id) end
    end
    table.sort(rest)
    table.move(rest, 1, #rest, #ids + 1, ids)
    return ids
end

function M.set_phase(id, phase, reason)
    local rec = get(id)
    local prev = rec.phase
    rec.phase = phase
    rec.since = clock.now()
    bus.emit('net.state', {net = id, phase = phase, prev = prev, reason = reason})
    dispatch.dirty()
end

local function cancel_timer(rec, field)
    if rec[field] then
        timer.cancel(rec[field])
        rec[field] = nil
    end
end

-- The transport is snowcone.connect unless a test injected another
local function transport_connect(...)
    local transport = HUB.boot.transport
    if transport then
        return transport.connect(...)
    end
    return snowcone.connect(...)
end

-- Layers =============================================================

-- Resolve the secrets in the configured layers and build the list that
-- snowcone.connect takes (from ircc's connect()). Raises on failure.
local function build_layers(t, configured)
    local layers = {}
    for _, layer in ipairs(configured) do
        if layer.type == 'tls' then
            local password = secrets.resolve(t, layer.client_password)
            local cert = secrets.resolve(t, layer.client_cert)
            local key = secrets.resolve(t, layer.client_key) or cert

            if cert then
                local ok, x509 = pcall(myopenssl.read_x509, cert)
                if not ok then error('Parse client cert failed: ' .. tostring(x509), 0) end
                cert = x509
            end

            if key then
                local ok, pkey
                if layer.use_store then
                    ok, pkey = pcall(myopenssl.pkey_from_store, key, true, password)
                else
                    ok, pkey = pcall(myopenssl.read_pem, key, true, password)
                end
                if not ok then error('Load client key failed: ' .. tostring(pkey), 0) end
                key = pkey
            end

            table.insert(layers, {
                type = 'tls',
                client_key = key,
                client_cert = cert,
                verify = layer.verify_host,
                sni = layer.sni_host,
                alpn = layer.alpn,
            })
        elseif layer.type == 'socks' or layer.type == 'http' then
            table.insert(layers, {
                type = layer.type,
                host = layer.host,
                port = layer.port,
                username = layer.username,
                password = secrets.resolve(t, layer.password),
            })
        else
            error('bad layer type: ' .. tostring(layer.type), 0)
        end
    end
    return layers
end

-- Closing ============================================================

local function schedule_reconnect(rec)
    if HUB.quitting or HUB.shut_down then return end
    local r = rec.cfg.reconnect
    local delay = rec.backoff * (1 + 0.25 * math.random())
    rec.reconnect_timer = timer.start('net', math.floor(delay * 1000), 'net.reconnect', rec.id, rec.attempt)
    rec.reconnect_at = clock.now() + delay
    rec.backoff = math.min(rec.backoff * 2, r.max_delay)
    log.add_net(rec.id, 'irc', 'reconnecting in %.1f s', delay)
end

--- End the current attempt: close the connection, cancel the network's
--- tasks, and reconnect if that is still the target.
---@param retry boolean|nil false prevents a reconnect
function M.finish(id, reason, retry)
    local rec = get(id)
    if rec.phase == 'idle' then return end

    if rec.conn then
        resources.close(rec.conn)
        rec.conn = nil
    end
    cancel_timer(rec, 'close_timer')
    task.cancel_net(id)

    local registered_for = rec.registered_at and clock.now() - rec.registered_at
    rec.irc = nil
    rec.registered_at = nil
    rec.lag_token = nil

    M.set_phase(id, 'idle', reason)
    log.add_net(id, 'irc', 'disconnected: %s', reason)
    bus.emit('net.closed', {net = id, reason = reason})

    if registered_for and registered_for >= M.stable_after then
        rec.backoff = rec.cfg.reconnect.min_delay
    end

    if rec.target == 'removed' then
        remove_record(id)
    elseif rec.target == 'connected' and retry ~= false then
        schedule_reconnect(rec)
    end
end

-- A connect attempt failed before there was a connection
local function failed(id, attempt, reason, retry)
    local rec = nets()[id]
    if rec == nil or rec.attempt ~= attempt then return end
    if not retry and rec.target == 'connected' then
        rec.target = 'idle' -- a configuration problem won't fix itself
    end
    M.finish(id, reason, retry)
end

-- Connecting =========================================================

local function connect_body(t, attempt)
    local id = t.net
    local rec = nets()[id]
    local cfg = rec.cfg

    local ok, layers = pcall(build_layers, t, cfg.layers)
    if not ok then
        return failed(id, attempt, layers, false)
    end

    if not cfg.server.host then
        return failed(id, attempt, 'connect host not specified', false)
    end

    local cb = dispatch.trampoline('net.on_event', id, attempt)
    local called, conn, err = pcall(transport_connect, cfg.server.host, cfg.server.port, layers, cb)
    if not called then
        -- bad arguments raise; treat that like any other configuration error
        return failed(id, attempt, 'failed to connect: ' .. tostring(conn), false)
    elseif not conn then
        return failed(id, attempt, 'failed to connect: ' .. tostring(err), true)
    end

    rec.conn = resources.add('connection', 'net:' .. id, conn, 'close')
    rec.irc = irc_model.new()
    rec.liveness = clock.now()
    M.set_phase(id, 'connecting')
    log.add_net(id, 'irc', 'connecting to %s', cfg.server.host)
end

--- Start connecting an idle network.
function M.connect(id)
    local rec = get(id)
    if rec.phase ~= 'idle' then
        error('network ' .. id .. ' is already ' .. rec.phase, 2)
    end
    cancel_timer(rec, 'reconnect_timer')
    rec.target = 'connected'
    rec.attempt = rec.attempt + 1
    rec.fingerprint = nil
    rec.restart_pending = false
    M.set_phase(id, 'resolving_secrets')
    task.spawn('connect', {net = id, owner = 'net'}, connect_body, rec.attempt)
end

--- Disconnect and stay disconnected. A registered connection gets a QUIT
--- and a few seconds for the server to close it.
function M.disconnect(id, quit_msg)
    local rec = get(id)
    if rec.target ~= 'removed' then
        rec.target = 'idle'
    end
    cancel_timer(rec, 'reconnect_timer')

    if rec.phase == 'connected' then
        local ok = pcall(send.send, id, 'QUIT', quit_msg or rec.cfg.quit_message or 'snowcone')
        if ok then
            M.set_phase(id, 'closing')
            rec.close_timer = timer.start('net', M.quit_grace_ms, 'net.force_close', id, rec.attempt)
            return
        end
    end

    if rec.phase ~= 'idle' and rec.phase ~= 'closing' then
        M.finish(id, 'disconnected')
    elseif rec.phase == 'idle' and rec.target == 'removed' then
        remove_record(id)
    end
end

--- Drop the current connection, if any, and connect again now.
function M.reconnect(id)
    local rec = get(id)
    rec.target = 'connected'
    if rec.phase ~= 'idle' then
        M.finish(id, 'reconnecting', false)
    end
    M.connect(id)
end

--- End every network now, without QUIT and without reconnecting, for
--- shutdown. Afterwards no network holds a connection or a timer.
function M.abandon_all()
    for _, id in ipairs(M.ids()) do
        local rec = nets()[id]
        if rec.target ~= 'removed' then
            rec.target = 'idle'
        end
        cancel_timer(rec, 'reconnect_timer')
        M.finish(id, 'shutdown', false)
    end
end

--- Number of networks with a connection or a connection attempt.
function M.live_count()
    local n = 0
    for _, rec in pairs(nets()) do
        if rec.phase ~= 'idle' then n = n + 1 end
    end
    return n
end

--- Disconnect every network, for quitting.
function M.quit_all(quit_msg)
    for _, id in ipairs(M.ids()) do
        local rec = nets()[id]
        if rec then
            M.disconnect(id, quit_msg)
        end
    end
end

-- Connection events ==================================================

local events = {}

function events.CON(rec, fingerprint)
    rec.fingerprint = fingerprint
    log.add_net(rec.id, 'irc', 'connected: %s', fingerprint)

    local want = rec.cfg.server.fingerprint
    if want and not string.match(fingerprint, want) then
        M.finish(rec.id, 'bad fingerprint')
        return
    end

    M.set_phase(rec.id, 'registering')
    bus.emit('net.connected', {net = rec.id, fingerprint = fingerprint})
    task.spawn('registration', {net = rec.id, owner = 'net'}, registration)
end

function events.MSG(rec, msg, flush)
    if not flush then
        dispatch.defer_draw()
    end

    do
        local time_tag = msg.tags.time
        msg.time = time_tag and time_tag:match '^%d%d%d%d%-%d%d%-%d%dT(%d%d:%d%d:%d%d)%.%d%d%dZ$'
                or os.date '!%H:%M:%S'
    end
    msg.timestamp = clock.now()

    local source = msg.source
    if source then
        msg.nick, msg.user, msg.host = source:match '^([^!]*)!([^@]*)@(.*)$'
    end

    local id = rec.id
    local irc = rec.irc
    send.record(rec, msg)
    rec.liveness = msg.timestamp
    dispatch.dirty()

    if batch.collect(irc, msg) then
        return
    end

    if msg.command == 'BATCH' then
        batch.BATCH(id, irc, msg)
    else
        local h = handlers.commands[msg.command]
        if h then
            local ok, err = xpcall(h, debug.traceback, rec, irc, msg)
            if not ok then
                dispatch.report('irc handler ' .. tostring(msg.command), err)
            end
        end
    end

    -- the handler may have ended the connection
    if nets()[id] ~= rec or rec.irc ~= irc then return end

    task.deliver_irc(id, msg)
    bus.emit('irc.message', {net = id, msg = msg})
end

function events.END(rec, err)
    if rec.phase == 'closing' then
        M.finish(rec.id, 'quit')
    else
        M.finish(rec.id, err or 'end of stream')
    end
end

local function on_event(id, attempt, ev, ...)
    if HUB.shut_down then return end
    local rec = nets()[id]
    if rec == nil or rec.attempt ~= attempt or rec.conn == nil then
        return -- stale: from an attempt that already ended
    end
    events[ev](rec, ...)
end

-- Liveness ===========================================================

-- Send a PING whose PONG measures lag; one at a time
local function lag_ping(id, rec, now)
    local token = string.format('%d', math.floor(now * 1000))
    if pcall(send.send, id, 'PING', token) then
        rec.lag_token = token
        rec.lag_sent = now
    end
end

--- Check every connection: PING a registered connection that has been
--- quiet for a while or not measured lately, close one that stays silent,
--- and time out connecting.
function M.check_liveness(now)
    for _, id in ipairs(M.ids()) do
        local rec = nets()[id]
        if rec and rec.conn then
            local phase = rec.phase
            if phase == 'connecting' then
                if now - rec.since >= M.connect_timeout then
                    M.finish(id, 'connect timeout')
                end
            elseif phase == 'registering' or phase == 'connected' then
                local silent = now - rec.liveness
                if silent >= M.timeout_after then
                    M.finish(id, 'ping timeout')
                elseif phase == 'connected' then
                    -- a PING that got no answer stops counting after a while
                    if rec.lag_token and now - rec.lag_sent >= M.lag_every then
                        rec.lag_token = nil
                    end
                    if not rec.lag_token
                    and (silent >= M.ping_after or now - (rec.lag_sent or 0) >= M.lag_every) then
                        lag_ping(id, rec, now)
                    end
                end
            end
        end
    end
end

-- Configuration ======================================================

local function new_record(net)
    return {
        id = net.id,
        cfg = net,
        target = net.autoconnect and 'connected' or 'idle',
        phase = 'idle',
        attempt = 0,
        since = clock.now(),
        backoff = net.reconnect.min_delay,
        restart_pending = false,
        console = OrderedMap.new(M.console_size),
    }
end

-- Settings that only take effect on a new connection (design 4.8)
local restart_keys <const> = {'server', 'layers', 'identity', 'sasl'}

-- Apply a network's new configuration. Everything is read from rec.cfg
-- when used, so features, mention, reconnect and oper settings apply at
-- once; connection settings wait for the next connection.
local function update_record(rec, net)
    local old = rec.cfg
    if rec.phase ~= 'idle' then
        for _, key in ipairs(restart_keys) do
            if not tablex.deepcompare(old[key], net[key]) then
                rec.restart_pending = true
            end
        end
    end
    rec.cfg = net
    rec.backoff = math.max(net.reconnect.min_delay, math.min(rec.backoff, net.reconnect.max_delay))
    if rec.target == 'removed' then
        rec.target = net.autoconnect and 'connected' or 'idle'
    end
end

--- Bring network records in line with the active configuration, and
--- connect networks that should be and aren't.
function M.apply_config(cfg)
    local wanted = {}
    for _, net in ipairs(cfg.networks) do
        wanted[net.id] = true
        local rec = nets()[net.id]
        if rec == nil then
            nets()[net.id] = new_record(net)
        else
            update_record(rec, net)
        end
    end

    for _, id in ipairs(M.ids()) do
        if not wanted[id] then
            local rec = nets()[id]
            rec.target = 'removed'
            M.disconnect(id)
        end
    end

    for _, id in ipairs(M.ids()) do
        local rec = nets()[id]
        if rec.target == 'connected' and rec.phase == 'idle' and not rec.reconnect_timer then
            M.connect(id)
        end
    end
end

-- Module interface ===================================================

function M.subscribe(sub)
    sub.on('clock.tick', function(ev)
        M.check_liveness(ev.now)
    end)
end

M.routes = {
    ['net.on_event'] = on_event,
    ['net.reconnect'] = function(id, attempt)
        local rec = nets()[id]
        if rec == nil then return end
        rec.reconnect_timer = nil
        if rec.attempt == attempt and rec.phase == 'idle' and rec.target == 'connected' then
            M.connect(id)
        end
    end,
    ['net.force_close'] = function(id, attempt)
        local rec = nets()[id]
        if rec and rec.attempt == attempt and rec.phase == 'closing' then
            rec.close_timer = nil
            M.finish(id, 'quit timeout')
        end
    end,
    ['net.check_liveness'] = M.check_liveness,
    ['net.connect'] = M.connect,
    ['net.disconnect'] = M.disconnect,
}

return M
