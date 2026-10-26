-- Network layer behaviour with a fake transport (design sections 6 and 9.4).
--
-- Run with:  snowcone script tests/hub/test-net.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local FakeTransport = dofile(here .. '/fake_transport.lua')

local function network(id, extra)
    local net = {
        id = id,
        server = {host = id .. '.test', port = 6667},
        identity = {nick = 'me'},
        reconnect = {min_delay = 1, max_delay = 8},
    }
    for k, v in pairs(extra or {}) do
        net[k] = v
    end
    return net
end

local function boot(networks, opts)
    local fake = FakeTransport.new()
    opts = opts or {}
    opts.transport = fake
    opts.config = {networks = networks}
    T.boot(opts)
    return fake
end

local function rec(id)
    return HUB.state.nets[id or 'test']
end

local function manager()
    return T.require 'hub.net.manager'
end

-- Events of one topic, recorded from now on
local function record(topic)
    local seen = {}
    local bus = T.require 'hub.runtime.bus'
    bus.on(HUB.current.bus, topic, 'test', function(ev) table.insert(seen, ev) end)
    return seen
end

-- Drive registration without CAP support beyond LS
local function register(c, nick, isupport)
    nick = nick or 'me'
    c:con()
    c:recv ':srv CAP * LS :multi-prefix'
    c:recv(':srv CAP ' .. nick .. ' ACK :multi-prefix')
    c:recv(':srv 001 ' .. nick .. ' :Welcome')
    c:recv(':srv 005 ' .. nick .. ' ' .. (isupport or 'CHANTYPES=#') .. ' :are supported')
    c:recv(':srv 376 ' .. nick .. ' :End of MOTD')
end

-- Fire a scheduled reconnect now instead of waiting for its timer
local function fire_reconnect(id)
    local r = rec(id)
    T.ok(r.reconnect_timer, 'reconnect scheduled for ' .. id)
    T.require 'hub.runtime.timer'.cancel(r.reconnect_timer)
    HUB.current.routes['net.reconnect'](id, r.attempt)
end

T.case('registration with CAP and SASL PLAIN', function()
    local fake = boot {network('test', {
        sasl = {
            automatic = {'PLAIN'},
            credentials = {{mechanism = 'PLAIN', username = 'u', password = 'p'}},
        },
    })}
    local registered = record 'net.registered'

    local c = T.ok(fake.last(), 'connection attempt')
    T.eq({c.host, c.port}, {'test.test', 6667}, 'address')
    T.eq(rec().phase, 'connecting', 'phase before CON')

    c:con 'tls=TLSv1.3 fp=abc'
    T.eq(rec().phase, 'registering', 'phase after CON')
    T.eq(c:take(), {'CAP LS 302', 'NICK me', 'USER me 0 * me'}, 'opening')

    c:recv ':srv CAP * LS * :multi-prefix unknown-cap'
    c:recv ':srv CAP * LS :sasl=PLAIN,EXTERNAL'
    T.eq(c:take(), {'CAP REQ :multi-prefix sasl'}, 'request')

    c:recv ':srv CAP me ACK :multi-prefix sasl'
    T.eq(c:take(), {'AUTHENTICATE PLAIN'}, 'mechanism')

    c:recv 'AUTHENTICATE +'
    T.eq(c:take(), {'AUTHENTICATE ' .. mybase64.to_base64 '\0u\0p'}, 'response')

    c:recv ':srv 900 me me!u@h u :You are now logged in as u'
    c:recv ':srv 903 me :SASL authentication successful'
    T.eq(c:take(), {'CAP END'}, 'end of negotiation')

    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 005 me CHANTYPES=# :are supported'
    T.eq(rec().phase, 'registering', 'still registering before MOTD')
    c:recv ':srv 376 me :End of MOTD'

    T.eq(rec().phase, 'connected', 'phase')
    T.eq(registered, {{net = 'test', nick = 'me'}}, 'registered event')
    T.eq(rec().irc.account, 'u', 'account')
    T.eq(rec().irc.caps_enabled, {['multi-prefix'] = true, sasl = true}, 'caps')
    T.eq(c:take(), {'MODE me'}, 'mode query after registration')

    -- the secret is masked in the console log
    local OrderedMap = T.require 'hub.lib.OrderedMap'
    for msg in OrderedMap.each(rec().console) do
        if msg.command == 'AUTHENTICATE' and msg.source == '>>>' and msg[1] ~= 'PLAIN' then
            T.eq(msg[1], '\x0304*', 'masked response')
        end
    end
end)

T.case('SASL failure falls back to the next credential', function()
    local fake = boot {network('test', {
        sasl = {
            automatic = {'first', 'second'},
            credentials = {
                {name = 'first', mechanism = 'PLAIN', username = 'a', password = 'wrong'},
                {name = 'second', mechanism = 'PLAIN', username = 'b', password = 'right'},
            },
        },
    })}
    HUB.boot.strict = true
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :sasl'
    c:recv ':srv CAP me ACK :sasl'
    c:recv 'AUTHENTICATE +'
    c:take()
    c:recv ':srv 904 me :SASL authentication failed'
    T.eq(c:take(), {'AUTHENTICATE PLAIN'}, 'second attempt')
    c:recv 'AUTHENTICATE +'
    T.eq(c:take(), {'AUTHENTICATE ' .. mybase64.to_base64 '\0b\0right'}, 'second credential')
    c:recv ':srv 903 me :SASL authentication successful'
    T.eq(c:take(), {'CAP END'}, 'end')
end)

T.case('a server without CAP registers directly', function()
    local fake = boot {network('test')}
    local c = fake.last()
    c:con()
    c:take()
    c:recv ':srv 421 me CAP :Unknown command'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 422 me :MOTD File is missing'
    T.eq(rec().phase, 'connected', 'phase')
    T.eq(c:take(), {'MODE me'}, 'no CAP END')
end)

T.case('nick in use during registration, then reclaimed with MONITOR', function()
    local fake = boot {network('test')}
    local c = fake.last()
    c:con()
    c:take()
    c:recv ':srv CAP * LS :'
    T.eq(c:take(), {'CAP END'}, 'no caps')

    c:recv ':srv 433 * me :Nickname is already in use'
    local sent = c:take()
    T.eq(#sent, 1, 'one reply')
    local temp = T.ok(sent[1]:match '^NICK (me%-%d%d%d%d%d)$', 'random nick: ' .. sent[1])

    c:recv(':srv 001 ' .. temp .. ' :Welcome')
    c:recv(':srv 005 ' .. temp .. ' MONITOR=100 :are supported')
    c:recv(':srv 376 ' .. temp .. ' :End of MOTD')
    T.eq(c:take(), {'MONITOR + me', 'MODE ' .. temp}, 'monitor the wanted nick')

    c:recv(':srv 731 ' .. temp .. ' :me')
    T.eq(c:take(), {'NICK me'}, 'reclaim when offline')

    local nicks = record 'irc.nick'
    c:recv(':' .. temp .. '!u@h NICK me')
    T.eq(rec().irc.nick, 'me', 'nick')
    T.eq(c:take(), {'MONITOR - me'}, 'stop monitoring')
    T.eq(nicks, {{net = 'test', old = temp, new = 'me', self = true}}, 'nick event')
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
    fake.refuse = 'connection refused'
    fake.last():finish 'reset'
    fire_reconnect 'test'
    T.eq(rec().phase, 'idle', 'idle after refusal')
    T.ok(rec().reconnect_timer, 'retry scheduled')

    local fake2 = boot {network('test', {server = {port = 6667}})}
    T.eq(#fake2.conns, 0, 'no attempt without host')
    T.eq(rec().target, 'idle', 'target dropped to idle')
    T.ok(not rec().reconnect_timer, 'no retry')
end)

T.case('casemapping from ISUPPORT', function()
    local fake = boot {network('a'), network('b')}
    register(fake.conns[1], 'me', 'CASEMAPPING=ascii')
    register(fake.conns[2])
    fake.conns[1]:recv ':me!u@h JOIN #x['
    fake.conns[2]:recv ':me!u@h JOIN #x['

    local irc_model = T.require 'hub.net.irc'
    T.ok(irc_model.get_channel(rec('a').irc, '#X['), 'ascii folds letters')
    T.eq(irc_model.get_channel(rec('a').irc, '#x{'), nil, 'ascii keeps [ and { distinct')
    T.ok(irc_model.get_channel(rec('b').irc, '#x{'), 'rfc1459 folds { to [')
end)

T.case('channel membership and modes', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c, 'me', 'PREFIX=(ov)@+ CHANMODES=b,k,l,imnt')
    c:recv ':me!u@h JOIN #chan'
    c:recv ':srv 353 me = #chan :@me +them other'
    c:recv ':srv MODE #chan +o-v+l them them 10'
    c:recv ':other!u@h PART #chan'

    local irc_model = T.require 'hub.net.irc'
    local irc = rec().irc
    local chan = irc_model.get_channel(irc, '#CHAN')
    T.eq(chan.members.ME.modes, {o = true}, 'my modes')
    T.eq(chan.members.THEM.modes, {o = true}, 'their modes')
    T.eq(chan.members.OTHER, nil, 'parted')
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

T.case('batches are collected and emitted whole', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c)
    local batches = record 'irc.batch'
    local messages = record 'irc.message'
    c:recv ':srv BATCH +b1 chathistory #c'
    c:recv '@batch=b1 :x!u@h PRIVMSG #c :one'
    c:recv '@batch=b1 :x!u@h PRIVMSG #c :two'
    c:recv ':srv BATCH -b1'
    T.eq(#batches, 1, 'one batch')
    T.eq(batches[1].type, 'chathistory', 'type')
    T.eq(batches[1].params, {'#c'}, 'params')
    T.eq(#batches[1].messages, 2, 'messages')
    T.eq(#messages, 2, 'only the BATCH lines are individual messages')
end)

T.case('secrets come from a command or a prompt', function()
    local prompts = {}
    local fake = boot {network('test', {
        server = {host = 'test.test', port = 6667, password = {command = 'printf', arguments = {'s3cret\nignored'}}},
        oper = {automatic = true, username = 'op', password = {prompt = 'oper password'}},
    })}
    local c = fake.last()
    c:con()
    T.eq(c:take(), {}, 'nothing sent while the command runs')
    T.sleep(500)
    T.eq(c:take(), {'CAP LS 302', 'PASS s3cret', 'NICK me', 'USER me 0 * me'}, 'PASS from the command')

    local bus = T.require 'hub.runtime.bus'
    bus.on(HUB.current.bus, 'task.prompt', 'test', function(ev) table.insert(prompts, ev) end)
    c:recv ':srv CAP * LS :'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 376 me :End of MOTD'
    c:take()
    T.eq(#prompts, 1, 'prompted')
    T.eq(prompts[1].label, 'oper password', 'label')
    T.require 'hub.runtime.task'.answer(prompts[1].task, 'opw')
    T.eq(c:take(), {'OPER op opw'}, 'OPER with the answer')
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

T.case('task timeouts, cancellation and DNS', function()
    local fake = boot {network('test')}
    register(fake.last())
    local task = T.require 'hub.runtime.task'
    local results = {}

    task.spawn('waiter', {net = 'test'}, function(t)
        results.wait = t:wait_irc({'NEVER'}, 20) or 'timed out'
    end)
    local sleeper = task.spawn('sleeper', {}, function(t)
        t:sleep(20)
        results.slept = true
    end)
    task.cancel(sleeper.id)
    -- lookups can't be cancelled natively; the late answer is ignored
    local dns = task.spawn('dns', {}, function(t)
        results.dns = {t:dnslookup 'localhost'}
    end)
    task.cancel(dns.id)
    task.spawn('dns2', {}, function(t)
        local err, addr = t:dnslookup 'localhost'
        results.dns2 = err == nil and addr ~= nil
    end)

    T.sleep(300)
    T.eq(results, {wait = 'timed out', dns2 = true},
        'timeout resumed with nil; cancelled tasks never resumed')
    T.eq(next(HUB.tasks), nil, 'no tasks left')
end)

T.case('a closing network cancels its tasks', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c)
    local task = T.require 'hub.runtime.task'
    local t = task.spawn('scoped', {net = 'test'}, function(t) t:wait_irc {'NEVER'} end)
    c:finish 'reset'
    T.eq(HUB.tasks[t.id], nil, 'cancelled')
end)

T.case('legacy configuration maps to network default', function()
    local fake = FakeTransport.new()
    T.boot {transport = fake, config = {
        server = {host = 'legacy.test', port = 6697},
        identity = {nick = 'old'},
        layers = {{type = 'tls'}},
    }}
    local cfg = HUB.state.config
    T.eq(#cfg.networks, 1, 'one network')
    local net = cfg.networks[1]
    T.eq(net.id, 'default', 'id')
    T.eq(net.features.snotice and net.features.chat, true, 'all features')
    T.eq(fake.last().host, 'legacy.test', 'connects')
    T.eq(fake.last().layers[1].type, 'tls', 'layers')
end)

T.case('an invalid configuration on reload leaves the old one active', function()
    boot {network('test')}
    local before = HUB.state.config
    local ok, err = T.reload {config = {networks = {{id = 'bad'}}}}
    T.eq(ok, false, 'reload fails')
    T.ok(err:find('Missing field', 1, true), err)
    T.ok(HUB.state.config == before, 'old configuration kept')

    ok, err = T.reload {config = {networks = {network('x', {features = {'nope'}})}}}
    T.eq(ok, false, 'unknown feature')
    T.ok(err:find('unknown feature nope', 1, true), err)

    ok, err = T.reload {config = {
        server = {host = 'h'}, identity = {nick = 'n'}, networks = {network('y')},
    }}
    T.eq(ok, false, 'mixed shapes')
    T.ok(err:find('must move into [[networks]]', 1, true), err)
end)

T.case('configuration constraints from the dashboard', function()
    T.boot()
    local config = T.require 'hub.runtime.config'
    for _, bad in ipairs {
        {identity = {nick = 'has space'}},
        {identity = {nick = 'n', user = 'a\nb'}},
        {identity = {nick = 'n', gecos = 'a\rb'}},
        {server = {host = 'h', password = 'line\nbreak'}},
        {oper = {username = 'o p', password = 'x'}},
        {challenge = {username = 'o\r', key = 'k'}},
    } do
        local raw = {server = {host = 'h', port = 1}, identity = {nick = 'n'}}
        for k, v in pairs(bad) do raw[k] = v end
        T.ok(not pcall(config.normalize, raw), 'rejected: ' .. require 'pl.pretty'.write(bad, ''))
    end
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
    c:recv(':x!u@h PRIVMSG me :one', false)
    c:recv(':x!u@h PRIVMSG me :two', false)
    T.eq(HUB.test_draws, 0, 'no draw mid-read')
    c:recv(':x!u@h PRIVMSG me :three', true)
    T.eq(HUB.test_draws, 1, 'one draw at the end of the read')
end)

-- Design 5.7, reload test 1
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

-- Design 5.7, reload test 4
T.case('a task waiting on wait_irc resumes after a reload', function()
    local fake = boot {network('test')}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :'
    c:take()

    T.ok(T.reload {}, 'reload while registration waits for 001')
    local sent = record 'irc.sent'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 376 me :End of MOTD'
    T.eq(rec().phase, 'connected', 'registration finished')
    T.eq(#sent, 1, 'its MODE went through the new generation')
    T.eq(sent[1].msg.command, 'MODE', 'command')
end)

T.run()
