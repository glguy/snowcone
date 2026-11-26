-- A network's connections (net/manager.lua): connecting through layers,
-- how a connection ends and what comes next, liveness, quitting, and
-- what a reload keeps.
--
-- Run with:  snowcone tests/hub/test-connect.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local FakeTransport = dofile(here .. '/fake_transport.lua')
local N = dofile(here .. '/netlib.lua')(T)
local network, boot, rec, manager, record, register = N.network, N.boot, N.rec, N.manager, N.record, N.register
local fire_reconnect = N.fire_reconnect

T.case("the server's ERROR is the reason the connection ended", function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c)
    local closed = record 'net.closed'
    c:recv 'ERROR :Closing Link: 192.0.2.1 (K-Lined)'
    c:finish 'end of stream'
    T.eq(closed[1].reason, 'server: Closing Link: 192.0.2.1 (K-Lined)', 'reason')
    local lines = T.log_lines 'irc'
    local found
    for _, line in ipairs(lines) do
        found = found or line:find('disconnected: server: Closing Link', 1, true)
    end
    T.ok(found, 'in the status log')
    T.ok(rec().reconnect_timer, 'still reconnects')
end)

T.case('progress is logged, and the current step kept until connected', function()
    local fake = boot {network('test')}
    local c = fake.last()
    c:progress('start', 'connecting to irc:6697')
    T.eq(rec().step, 'connecting to irc:6697', 'step')
    c:progress('done', 'TCP connected to 192.0.2.1:6697', {layer = 0, type = 'tcp', endpoint = '192.0.2.1:6697'})
    c:progress('start', 'TLS with irc 100%')
    T.eq(rec().step, 'TLS with irc 100%', 'next step')
    c:progress('done', 'TLS with irc 100% established', {layer = 1, type = 'tls', key = 'ab'})
    local found = {}
    for _, line in ipairs(T.log_lines 'irc') do
        if line:find('established', 1, true) or line:find('connected to', 1, true) then
            table.insert(found, line)
        end
    end
    T.eq(found, {'TCP connected to 192.0.2.1:6697', 'TLS with irc 100% established'}, 'finished steps are logged, once')
    c:con()
    T.eq(rec().step, nil, 'cleared once connected')
    T.eq(T.log_lines('irc')[#T.log_lines 'irc'], 'TLS with irc 100% established', 'the last step ends the log')
    T.eq(rec().transport, 'tcp=192.0.2.1:6697 tls=ab', 'described')

    c:finish 'gone'
    fire_reconnect 'test'
    local second = fake.last()
    second:progress('start', 'connecting to irc:6697')
    c:progress('start', 'stale')
    T.eq(rec().step, 'connecting to irc:6697', 'an earlier attempt is ignored')
    local closed = record 'net.closed'
    HUB.current.routes['net.check_liveness'](rec().since + 61)
    T.eq(closed[1].reason, 'connect timeout: connecting to irc:6697', 'a timeout names the step')
    T.eq(rec().step, nil, 'cleared when the attempt ends')
end)

T.case('a ban waits the longest delay, and a stable session resets it', function()
    local fake = boot {network('test')}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :'
    local closed = record 'net.closed'
    c:recv ':srv 465 * :You are banned from this server- spamming'
    c:recv 'ERROR :Closing Link: 192.0.2.1 (K-Lined)'
    c:finish 'end of stream'
    T.eq(closed[1].kind, 'banned', 'kind')
    T.eq(closed[1].reason, 'banned: You are banned from this server- spamming', 'the 465 text')
    T.eq(rec().backoff, 8, 'at max_delay')
    T.ok(rec().reconnect_at - T.require 'hub.runtime.clock'.now() >= 8, 'retry waits it')
    T.eq(rec().closed.text, closed[1].reason, 'kept for the views')

    fire_reconnect 'test'
    c = fake.last()
    register(c)
    T.eq(rec().closed, nil, 'forgotten once registered')
    rec().registered_at = rec().registered_at - 61
    c:finish 'gone'
    T.eq(rec().backoff, 2, 'reset after a stable session, then doubled')
end)

T.case('each way a connection ends has its kind', function()
    local fake = boot {network('test')}
    local closed = record 'net.closed'
    local c = fake.last()
    register(c)
    c:finish 'reset by peer'
    fire_reconnect 'test'
    c = fake.last()
    register(c)
    manager().reconnect 'test'
    c = fake.last()
    register(c)
    manager().disconnect 'test'
    c:finish()
    local kinds = {}
    for _, ev in ipairs(closed) do table.insert(kinds, ev.kind .. ' ' .. ev.reason) end
    T.eq(kinds, {'stream reset by peer', 'local reconnecting', 'local quit'}, 'kinds')
    T.eq(rec().reconnect_timer, nil, 'no reconnect after our own')
end)

T.case('events from an earlier attempt are dropped', function()
    local fake = boot {network('test')}
    local first = fake.last()
    register(first)
    first:take()

    manager().reconnect 'test'
    T.ok(first.closed, 'first connection closed')
    local second = fake.last()
    T.ok(second ~= first, 'new connection')
    T.eq(rec().attempt, 2, 'attempt')

    local messages = record 'irc.message'
    first:recv ':srv NOTICE me :stale'
    first:finish 'late end'
    T.eq(messages, {}, 'stale message ignored')
    T.eq(rec().phase, 'connecting', 'stale END ignored')

    second:con()
    T.eq(rec().phase, 'registering', 'new attempt proceeds')
end)

T.case('two networks are independent', function()
    local fake = boot {network('a'), network('b')}
    T.eq(#fake.conns, 2, 'both connect')
    local ca, cb = fake.conns[1], fake.conns[2]
    T.eq({ca.host, cb.host}, {'a.test', 'b.test'}, 'hosts')
    register(ca)
    register(cb, 'me', 'CASEMAPPING=ascii')

    local messages = record 'irc.message'
    ca:recv ':x!u@h PRIVMSG me :to a'
    cb:recv ':y!u@h PRIVMSG me :to b'
    T.eq(#messages, 2, 'two messages')
    T.eq({messages[1].net, messages[1].msg[2]}, {'a', 'to a'}, 'first attributed to a')
    T.eq({messages[2].net, messages[2].msg[2]}, {'b', 'to b'}, 'second attributed to b')

    ca:finish 'reset'
    T.eq(rec('a').phase, 'idle', 'a closed')
    T.eq(rec('b').phase, 'connected', 'b untouched')
    T.ok(not cb.closed, 'b connection open')
end)

T.case('reconnect backoff grows and resets after a stable session', function()
    local fake = boot {network('test')}
    local function drop()
        fake.last():finish 'reset'
        local backoff = rec().backoff
        fire_reconnect 'test'
        return backoff
    end

    T.eq(rec().backoff, 1, 'initial')
    T.eq({drop(), drop(), drop(), drop()}, {2, 4, 8, 8}, 'doubles up to max_delay')

    register(fake.last())
    rec().registered_at = rec().registered_at - 61
    T.eq(drop(), 2, 'reset to min_delay after a stable session, then doubled')
end)

T.case('a refused connection retries; a configuration error does not', function()
    local fake = boot({network('test')}, {})
    fake.last():finish 'reset'
    fire_reconnect 'test'
    -- a refusal ends the attempt like any other stream error
    fake.last():finish 'connection refused'
    T.eq(rec().phase, 'idle', 'idle after refusal')
    T.ok(rec().reconnect_timer, 'retry scheduled')

    local fake2 = boot {network('test', {layers = {{type = 'tls', client_cert = 'not a certificate'}}})}
    T.eq(#fake2.conns, 0, 'no attempt with an unreadable certificate')
    T.eq(rec().target, 'idle', 'target dropped to idle')
    T.ok(not rec().reconnect_timer, 'no retry')
end)

T.case('a socks password that resolves empty stops the connect', function()
    local fake = boot {network('test', {layers = {{type = 'socks', host = 'p', port = 1080,
        username = 'u', password = {command = 'printf', arguments = {''}}}}})}
    T.wait_until(function() return rec().target == 'idle' end, 'target dropped to idle')
    T.eq(#fake.conns, 0, 'no attempt')
    T.ok(not rec().reconnect_timer, 'no retry')
    T.ok(table.concat(T.log_lines 'irc', '\n'):find('socks password must not be empty', 1, true), 'reason logged')
end)

local pin_a <const> = string.rep('a', 64)

local pin_b <const> = string.rep('b', 64)

T.case('a TLS key that fails its pin is not retried', function()
    local fake = boot {network('test', {layers = {{type = 'tls', pin = pin_a}}})}
    fake.last():con {{type = 'tls', key = pin_b}}
    T.eq(rec().phase, 'idle', 'dropped')
    T.eq(rec().target, 'idle', 'target dropped to idle')
    T.ok(not rec().reconnect_timer, 'no retry')
    T.eq(T.log_lines('irc')[#T.log_lines 'irc'], 'disconnected: layers[1]: TLS key ' .. pin_b .. ' does not match pin', 'logged')
end)

T.case('a failed pin closes as soon as its layer is established', function()
    local fake = boot {network('test', {layers = {
        {type = 'tls', pin = pin_a},
        {type = 'socks', host = 'p', port = 1080},
    }})}
    local c = fake.last()
    c:progress('done', 'connected', {layer = 0, type = 'tcp', endpoint = '192.0.2.1:443'})
    T.ok(not c.closed, 'still connecting')
    c:progress('done', 'TLS', {layer = 1, type = 'tls', key = pin_b})
    T.ok(c.closed, 'closed before the next layer')
    T.eq(rec().target, 'idle', 'not retried')
end)

T.case('a pin whose layer was never reported fails at CON', function()
    local fake = boot {network('test', {layers = {{type = 'tls', pin = pin_a}}})}
    local c = fake.last()
    c:con()
    T.ok(c.closed, 'closed')
    T.eq(rec().phase, 'idle', 'not registering')
    T.eq(c:take(), {}, 'nothing sent')

    -- nor does an earlier attempt's key count for a later one
    fake = boot {network('test', {layers = {{type = 'tls', pin = pin_a}}})}
    fake.last():con {{type = 'tls', key = pin_a}}
    T.eq(rec().phase, 'registering', 'matched')
    fake.last():finish 'gone'
    fire_reconnect 'test'
    fake.last():con()
    T.eq(rec().phase, 'idle', 'checked afresh')
end)

T.case('a reload while connecting keeps the pins the attempt began with', function()
    local tls_a = {type = 'tls', pin = pin_a}
    local socks = {type = 'socks', host = 'p', port = 1080}
    local function change(layers)
        local cfg = T.require('pl.tablex').deepcopy(rec().cfg)
        cfg.layers = layers
        manager().apply_config {networks = {cfg}}
    end

    local fake = boot {network('test', {layers = {tls_a, socks}})}
    change {socks}
    fake.last():progress('done', 'TLS', {layer = 1, type = 'tls', key = pin_b})
    T.ok(fake.last().closed, 'a dropped pin still counts')

    fake = boot {network('test', {layers = {tls_a}})}
    change {{type = 'tls', pin = pin_b}}
    fake.last():con {{type = 'tls', key = pin_a}}
    T.eq(rec().phase, 'registering', 'a new pin waits for the next connection')
end)

T.case('a connection event that raises ends the connection', function()
    for _, ev in ipairs {'PROGRESS', 'CON'} do
        local fake = boot {network('test')}
        local c = fake.last()
        rec().pins = nil -- raises in the pin check
        pcall(function()
            if ev == 'CON' then c:con() else c:progress('done', 'x', {layer = 1, type = 'http'}) end
        end)
        T.ok(c.closed, ev .. ' closed it')
        T.eq(rec().phase, 'idle', ev .. ' not connected')
        T.ok(rec().reconnect_timer, ev .. ' retries')
    end
end)

T.case('nothing can be sent before the connection is established', function()
    local fake = boot {network('test')}
    local send = T.require 'hub.net.send'
    T.ok(not pcall(send.send, 'test', 'PRIVMSG', 'NickServ', 'identify x'), 'refused')
    T.ok(not send.ready 'test', 'not ready')
    T.eq(fake.last():take(), {}, 'nothing sent')
end)

T.case('each pin is checked against its own TLS layer', function()
    local layers = {
        {type = 'tls', pin = pin_a},
        {type = 'socks', host = 'p', port = 1080},
        {type = 'tls', pin = string.upper(pin_b)},
    }
    local fake = boot {network('test', {layers = layers})}
    fake.last():con {{type = 'tls', key = pin_a}, {type = 'socks', endpoint = 'p:1080'}, {type = 'tls', key = pin_b}}
    T.eq(rec().phase, 'registering', 'both pins match, in any case')

    fake = boot {network('test', {layers = layers})}
    fake.last():con {{type = 'tls', key = pin_b}, {type = 'socks', endpoint = 'p:1080'}, {type = 'tls', key = pin_a}}
    T.eq(T.log_lines('irc')[#T.log_lines 'irc'], 'disconnected: layers[1]: TLS key ' .. pin_b .. ' does not match pin',
        'the keys in the wrong order fail')
end)

T.case('server.path connects to a local socket', function()
    local fake = boot {network('test', {server = {path = '/run/ircd.sock'}})}
    local c = fake.last()
    T.eq({c.host, c.port}, {'/run/ircd.sock', 0}, 'the native call takes the path with port 0')
end)

T.case('liveness: PING once when quiet, close when silent', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c)
    c:take()

    local clock = T.require 'hub.runtime.clock'
    local now = clock.now()
    rec().liveness = now - 31
    HUB.current.routes['net.check_liveness'](now)
    T.ok(c:take()[1]:match '^PING %d+$', 'ping sent')
    HUB.current.routes['net.check_liveness'](now + 1)
    T.eq(c:take(), {}, 'only once')

    rec().liveness = now - 61
    HUB.current.routes['net.check_liveness'](now)
    T.eq(rec().phase, 'idle', 'closed')
    T.ok(c.closed, 'connection closed')
    T.ok(rec().reconnect_timer, 'reconnect scheduled')
end)

T.case('quit sends QUIT and exits when the server closes', function()
    local fake = boot {network('a'), network('b')}
    register(fake.conns[1])
    fake.conns[1]:take()

    HUB.current.routes['app.quit']()
    T.eq(fake.conns[1]:take(), {'QUIT snowcone'}, 'QUIT sent')
    T.ok(fake.conns[2].closed, 'unregistered connection closed at once')
    T.eq(rec('a').phase, 'closing', 'waiting for the server')
    T.ok(not HUB.shut_down, 'not yet shut down')

    fake.conns[1]:finish()
    T.eq(rec('a').phase, 'idle', 'closed')
    T.ok(HUB.shut_down, 'shut down')
    T.eq(rec('a').reconnect_timer, nil, 'no reconnect')
end)

T.case('/disconnect quits and stays down; /connect and /reconnect connect again', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c)
    c:take()
    T.command 'disconnect see you'
    T.eq(c:take(), {'QUIT :see you'}, 'QUIT with the message')
    T.eq({rec().phase, rec().target}, {'closing', 'idle'}, 'closing, to stay down')
    c:finish 'closed'
    T.eq(rec().phase, 'idle', 'down')
    T.eq(rec().reconnect_timer, nil, 'and staying down')

    T.command 'connect'
    T.eq(#fake.conns, 2, 'connecting again')
    c = fake.last()
    register(c)
    c:take()
    T.command 'reconnect'
    T.ok(c.closed, 'the connection dropped')
    T.eq(#fake.conns, 3, 'and another made at once')
    T.eq(rec().target, 'connected', 'to stay connected')
end)

T.case('a QUIT the server never answers closes the connection after its grace', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c)
    T.command 'disconnect'
    local r = rec()
    T.ok(r.close_timer, 'waiting for the server')
    T.require 'hub.runtime.timer'.cancel(r.close_timer)
    HUB.current.routes['net.force_close']('test', r.attempt)
    T.ok(c.closed, 'closed')
    T.eq({r.phase, r.closed.kind, r.closed.text}, {'idle', 'local', 'quit timeout'}, 'why')
end)

T.case('/dump writes the console as client and server lines, tags escaped', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c)
    c:recv [[@msgid=x;note=a\sb\:c :srv NOTICE me :hello there]]
    local file = os.tmpname()
    T.cleanup(function() os.remove(file) end)
    T.command('dump ' .. file)
    local lines = {}
    for line in io.lines(file) do table.insert(lines, line) end
    T.eq(lines[1], 'C: CAP LS :302', 'oldest first, our lines as C:')
    local last = lines[#lines]
    T.ok(last:find('^S: @') and last:find('note=a\\sb\\:c', 1, true) and last:find('msgid=x', 1, true)
        and last:find(' :srv NOTICE me :hello there$'), 'server lines as S:, tags as sent: ' .. last)
    T.ok(table.concat(lines, '\n'):find('S: :srv 001 me :Welcome', 1, true), 'numerics as three digits')
end)

T.case('shutdown with a live connection does not reconnect', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c)
    local task = T.require 'hub.runtime.task'
    local child = task.spawn('child', {}, function(t) t:execute('sleep', {'60'}, '') end)
    task.spawn('dns', {}, function(t) t:dnslookup 'localhost' end)
    HUB.current.routes['app.shutdown']()
    T.eq(next(HUB.tasks), nil, 'tasks canceled')
    T.eq(child.process, nil, 'child killed') -- else the script outlives ctest's timeout
    T.ok(c.closed, 'connection closed')
    T.eq(rec().phase, 'idle', 'idle')
    T.eq(rec().target, 'idle', 'target idle')
    c:finish 'end of stream' -- the close arrives afterwards
    T.eq(#fake.conns, 1, 'no new attempt')
    T.eq(rec().reconnect_timer, nil, 'no reconnect scheduled')
    T.eq(next(HUB.resources.items), nil, 'no resources left')
end)

T.case('the websocket reaches the transport after the layers', function()
    local fake = boot {network('test', {
        layers = {{type = 'tls'}, {type = 'socks', host = 'p', port = 1080}},
        websocket = {path = '/irc', origin = 'https://irc.example', subprotocols = {}},
    })}
    T.eq(#fake.last().layers, 3, 'one more layer')
    T.eq(fake.last().layers[3], {type = 'websocket', path = '/irc', origin = 'https://irc.example', subprotocols = {}},
        'fields passed, last')
end)

T.case('lines from one read draw once', function()
    local fake = boot({network('test')}, {
        modules = {'hub.test.screen'},
        overrides = {['hub.test.screen'] =
            "return {routes = {['ui.draw'] = function() HUB.test_draws = (HUB.test_draws or 0) + 1 end}}"},
    })
    local c = fake.last()
    register(c)
    HUB.test_draws = 0
    -- nothing drawn lately or held
    HUB.drawn_at, HUB.draw_timer = nil, nil
    c:recv(':x!u@h PRIVMSG me :one', false)
    c:recv(':x!u@h PRIVMSG me :two', false)
    T.eq(HUB.test_draws, 0, 'no draw mid-read')
    c:recv(':x!u@h PRIVMSG me :three', true)
    T.eq(HUB.test_draws, 1, 'one draw at the end of the read')
end)

T.case('reads draw once per interval, other changes at once', function()
    local fake = boot({network('test')}, {
        modules = {'hub.test.screen'},
        overrides = {['hub.test.screen'] =
            "return {routes = {['ui.draw'] = function() HUB.test_draws = (HUB.test_draws or 0) + 1 end, ['test.nothing'] = function() end}}"},
    })
    local c = fake.last()
    register(c)
    local pace = T.require 'hub.runtime.pace'
    local dispatch = T.require 'hub.runtime.dispatch'
    -- nothing drawn lately or held, and a hold lasts an interval
    local function start(interval)
        T.require 'hub.runtime.timer'.cancel(HUB.draw_timer)
        pace.interval = interval
        HUB.drawn_at, HUB.draw_timer = nil, nil
        HUB.test_draws = 0
    end

    start(60)
    for _ = 1, 5 do c:recv ':x!u@h PRIVMSG me :hi' end
    T.eq(HUB.test_draws, 1, 'the first read draws, the rest are held')
    -- another callback draws them, whatever it does
    dispatch.trampoline 'test.nothing' ()
    T.eq(HUB.test_draws, 2, 'drawn by another callback')

    start(60)
    c:recv ':x!u@h PRIVMSG me :hi'
    pace.interval = 0.5
    c:recv ':x!u@h PRIVMSG me :hi'
    T.wait_until(function() return HUB.test_draws == 2 end, 'the timer draws')
    T.eq(HUB.dirty, false, 'nothing left to draw')
end)

T.case('reload applies configuration changes per network', function()
    local fake = boot {network('a'), network('b')}
    local ca, cb = fake.conns[1], fake.conns[2]
    register(ca)
    register(cb)
    cb:take()
    local before = #fake.conns

    local changed = network('a', {
        server = {host = 'a.test', port = 7000},
        reconnect = {min_delay = 2, max_delay = 3},
        features = {'chat'},
    })
    T.ok(T.reload {config = {networks = {changed, network('c')}}}, 'reload')
    -- subscriptions belong to a generation, so after the reload
    local removed = record 'net.removed'

    -- a: connection settings wait, the rest applies now
    T.eq(rec('a').phase, 'connected', 'a stays connected')
    T.ok(not ca.closed, 'a connection kept')
    T.eq(rec('a').restart_pending, true, 'restart pending')
    T.eq(rec('a').cfg.features, {chat = true}, 'features applied')
    T.eq(rec('a').backoff, 2, 'backoff clamped to the new range')

    -- b: removed, with QUIT, and dropped once closed
    T.eq(cb:take(), {'QUIT snowcone'}, 'b sent QUIT')
    T.eq(rec('b').phase, 'closing', 'b quitting')
    cb:finish()
    T.eq(rec('b'), nil, 'b record dropped')
    T.eq(removed, {{net = 'b'}}, 'net.removed')

    -- c: new and autoconnected
    T.eq(#fake.conns, before + 1, 'one new connection')
    T.eq(fake.last().host, 'c.test', 'c connecting')

    -- /reconnect applies the new server settings
    manager().reconnect 'a'
    T.eq(fake.last().port, 7000, 'new port used')
    T.eq(rec('a').restart_pending, false, 'nothing pending')
end)

T.case('an idle network is removed at once', function()
    local fake = boot {network('a'), network('b', {autoconnect = false})}
    T.eq(#fake.conns, 1, 'b not autoconnected')
    T.eq(rec('b').target, 'idle', 'b idle')
    T.ok(T.reload {config = {networks = {network('a')}}}, 'reload')
    T.eq(rec('b'), nil, 'gone')
    T.eq(rec('a').phase, 'connecting', 'a untouched')
end)

T.case('lag is measured with a PING of our own', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c)
    c:take()
    local now = T.require 'hub.runtime.clock'.now()
    HUB.current.routes['net.check_liveness'](now)
    local token = T.ok(c:take()[1]:match '^PING (%d+)$', 'lag ping')
    HUB.current.routes['net.check_liveness'](now + 1)
    T.eq(c:take(), {}, 'one at a time')
    c:recv(':srv PONG srv ' .. token)
    T.ok(rec().lag and rec().lag >= 0, 'lag recorded')
    T.eq(rec().lag_token, nil, 'answered')
    HUB.current.routes['net.check_liveness'](now + 30)
    T.eq(c:take(), {}, 'not again until lag_every')
    rec().liveness = now + 60 -- traffic kept flowing
    HUB.current.routes['net.check_liveness'](now + 61)
    T.ok(c:take()[1]:match '^PING %d+$', 'measured again')
end)

T.case('the all-networks console interleaves traffic', function()
    local fake = boot {network('a'), network('b')}
    register(fake.conns[1])
    register(fake.conns[2])
    local OrderedMap = T.require 'hub.lib.OrderedMap'
    OrderedMap.reset(HUB.state.console_all)

    fake.conns[1]:recv ':x!u@h PRIVMSG me :one'
    T.require 'hub.net.send'.send('b', 'PRIVMSG', 'y', 'two')
    fake.conns[2]:recv ':y!u@h PRIVMSG me :three'

    local seen = {}
    for entry in OrderedMap.reveach(HUB.state.console_all) do
        table.insert(seen, entry.net .. ' ' .. entry.msg.source .. ' ' .. entry.msg[2])
    end
    T.eq(seen, {'a x!u@h one', 'b >>> two', 'b y!u@h three'}, 'both networks, both directions')
end)

T.case('reload keeps connections and console, and new code handles messages', function()
    local marker = function(version)
        return {
            modules = {'hub.test.marker'},
            overrides = {['hub.test.marker'] = string.format([[
return {subscribe = function(sub)
    sub.on('irc.message', function(ev) table.insert(HUB.test_seen, {%q, ev.msg[2]}) end)
end}]], version)},
        }
    end
    local fake = FakeTransport.new()
    T.boot {transport = fake, config = {networks = {network('test')}},
        modules = marker('v1').modules, overrides = marker('v1').overrides}
    HUB.test_seen = {}
    local c = fake.last()
    register(c)
    HUB.test_seen = {}
    c:recv ':x!u@h PRIVMSG me :before'

    T.ok(T.reload(marker 'v2'), 'reload')
    T.eq(#fake.conns, 1, 'no new connection')
    T.ok(not c.closed, 'connection kept')
    c:recv ':x!u@h PRIVMSG me :after'

    T.eq(HUB.test_seen, {{'v1', 'before'}, {'v2', 'after'}}, 'handled by each generation')
    local texts = {}
    for msg in T.require 'hub.lib.OrderedMap'.reveach(rec().console) do
        if msg.command == 'PRIVMSG' then table.insert(texts, msg[2]) end
    end
    T.eq(texts, {'before', 'after'}, 'console has both')
end)

T.run()
