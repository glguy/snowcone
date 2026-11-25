-- Registration (net/registration.lua): CAP and SASL, the welcome and
-- the end of MOTD, refusals, secrets, and what a new connection restores.
--
-- Run with:  snowcone tests/hub/test-registration.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local N = dofile(here .. '/netlib.lua')(T)
local network, boot, rec, record, register, fire_reconnect = N.network, N.boot, N.rec, N.record, N.register, N.fire_reconnect

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

    c:con()
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

T.case('/sasl uses the named credential, or the automatic ones, or the first', function()
    local fake = boot {network('test', {sasl = {credentials = {
        {name = 'first', mechanism = 'PLAIN', username = 'a', password = 'pa'},
        {name = 'other', mechanism = 'PLAIN', username = 'b', password = 'pb'},
    }}})}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :sasl'
    c:recv ':srv CAP me ACK :sasl'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 376 me :End of MOTD'
    c:take()

    T.command 'sasl other'
    T.eq(c:take(), {'AUTHENTICATE PLAIN'}, 'by name')
    c:recv 'AUTHENTICATE +'
    T.eq(c:take(), {'AUTHENTICATE ' .. mybase64.to_base64 '\0b\0pb'}, 'the named credential')
    c:recv ':srv 903 me :SASL authentication successful'

    T.command 'sasl'
    c:recv 'AUTHENTICATE +'
    T.eq(c:take(), {'AUTHENTICATE PLAIN', 'AUTHENTICATE ' .. mybase64.to_base64 '\0a\0pa'},
        'without automatic, the first credential')
    c:recv ':srv 903 me :SASL authentication successful'

    rec().cfg.sasl.automatic = {'other', 'first'}
    T.command 'sasl'
    c:recv 'AUTHENTICATE +'
    T.eq(c:take(), {'AUTHENTICATE PLAIN', 'AUTHENTICATE ' .. mybase64.to_base64 '\0b\0pb'}, 'the automatic list')
    c:recv ':srv 904 me :SASL authentication failed'
    c:recv 'AUTHENTICATE +'
    T.eq(c:take(), {'AUTHENTICATE PLAIN', 'AUTHENTICATE ' .. mybase64.to_base64 '\0a\0pa'}, 'in order')
    c:recv ':srv 903 me :SASL authentication successful'
    T.eq(next(HUB.tasks), nil, 'finished')
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

T.case('a server that ignores CAP registers on its welcome', function()
    local fake = boot {network('test')}
    local c = fake.last()
    c:con()
    c:take()
    c:recv ':srv 001 other :Welcome'
    c:recv ':srv 422 other :MOTD File is missing'
    T.eq(rec().phase, 'connected', 'phase')
    T.eq(rec().irc.nick, 'other', 'nick from the welcome')
    T.eq(c:take(), {'MODE other'}, 'no CAP END')
end)

T.case('identity.bot sets the named bot mode before the registered event', function()
    local fake = boot {network('test', {identity = {nick = 'me', bot = true}})}
    local c = fake.last()
    local bus = T.require 'hub.runtime.bus'
    local sent_before
    bus.on(HUB.current.bus, 'net.registered', 'test', function()
        sent_before = c:take()
    end)
    register(c, 'me', 'CHANTYPES=# BOT=B')
    T.eq(sent_before[#sent_before], 'MODE me +B', 'bot mode, before the event')
    T.eq(c:take(), {'MODE me'}, 'then the mode query')
end)

T.case('identity.bot without ISUPPORT BOT sends no mode', function()
    local fake = boot {network('test', {identity = {nick = 'me', bot = true}})}
    local c = fake.last()
    local logged = record 'log'
    register(c)
    local sent = c:take()
    T.eq(sent[#sent], 'MODE me', 'only the mode query')
    local found
    for _, entry in ipairs(logged) do
        found = found or entry.text:find 'names no bot mode'
    end
    T.ok(found, 'logged')
end)

T.case('buffers with join are joined after registration, on every connection', function()
    local long, buffers = {}, {}
    for i = 1, 40 do
        long[i] = ('#channel%02d'):format(i)
        table.insert(buffers, {name = long[i], join = true})
        table.insert(buffers, {name = ('#other%02d'):format(i)})
    end
    table.insert(buffers, {name = '#off', join = false})
    local fake = boot {network('test', {buffers = buffers})}
    local c = fake.last()
    register(c)
    local joins = {}
    for _, line in ipairs(c:take()) do
        local names = line:match '^JOIN (.*)$'
        if names then table.insert(joins, names) end
    end
    T.eq(#joins, 2, 'split over two lines')
    T.eq(table.concat(joins, ','), table.concat(long, ','), 'every channel with join, in order')

    c:finish 'gone'
    fire_reconnect 'test'
    c = fake.last()
    register(c)
    local again = 0
    for _, line in ipairs(c:take()) do
        if line:match '^JOIN ' then again = again + 1 end
    end
    T.eq(again, 2, 'joined again after reconnecting')
end)

T.case('a new connection rejoins the channels we were in, with their keys, and sets us away', function()
    local isupport = 'CHANTYPES=# CHANMODES=b,k,l,imnst'
    local fake = boot {network('test', {buffers = {
        {name = '#conf', join = true, key = 'ck'},
        {name = '#plain', key = 'unused'},
    }})}
    local c = fake.last()
    register(c, 'me', isupport)
    local first
    for _, line in ipairs(c:take()) do
        first = first or line:match '^JOIN .*'
    end
    T.eq(first, 'JOIN #conf ck', 'a configured key')
    c:recv ':me!u@h JOIN #conf'

    -- keys sent by hand, by position
    T.command 'quote JOIN #k,#plain,#b,#c,#gone secret'
    for _, name in ipairs {'#k', '#plain', '#b', '#c', '#gone'} do
        c:recv(':me!u@h JOIN ' .. name)
    end
    c:recv ':op!u@h KICK #b me :bye'
    c:recv ':op!u@h MODE #c +k newkey'
    c:recv ':me!u@h PART #plain'
    T.command 'quote AWAY :gone fishing'
    c:take()

    -- a channel left while disconnected (its buffer closed) isn't rejoined
    c:finish 'gone'
    T.require 'hub.net.intent'.left(rec(), nil, '#GONE')
    fire_reconnect 'test'
    c = fake.last()
    register(c, 'me', isupport)
    local sent = {}
    for _, line in ipairs(c:take()) do
        if line:match '^JOIN ' or line:match '^AWAY ' then table.insert(sent, line) end
    end
    T.eq(sent, {'AWAY :gone fishing', 'JOIN #conf,#k,#c ck,secret,newkey'},
        'away, then kept channels, keyed first')

    -- back, and a key removed
    c:recv ':me!u@h JOIN #conf'
    c:recv ':me!u@h JOIN #c'
    c:recv ':op!u@h MODE #c -k *'
    T.command 'quote AWAY'
    c:take()
    c:finish 'gone'
    fire_reconnect 'test'
    c = fake.last()
    register(c, 'me', isupport)
    sent = {}
    for _, line in ipairs(c:take()) do
        if line:match '^JOIN ' or line:match '^AWAY' then table.insert(sent, line) end
    end
    T.eq(sent, {'JOIN #conf,#k,#c ck,secret'}, 'a channel without its key, and not away')
end)

T.case('a password refused during registration is a configuration error', function()
    local fake = boot {network('test', {registration = {password = 'wrong'}})}
    local c = fake.last()
    c:con()
    c:take()
    c:recv ':srv CAP * LS :'
    c:take()
    c:recv ':srv 464 * :Password incorrect'
    T.ok(c.closed, 'connection closed')
    T.eq(rec().target, 'idle', 'staying disconnected')
    T.eq(rec().reconnect_timer, nil, 'no reconnect')
    local lines = T.log_lines 'irc'
    T.ok(lines[#lines]:find('registration.password: the server refuses it: Password incorrect', 1, true),
        lines[#lines])
end)

T.case('an erroneous nick during registration is a configuration error', function()
    local fake = boot {network('test', {identity = {nick = 'averylongnick'}})}
    local c = fake.last()
    c:con()
    c:take()
    c:recv ':srv CAP * LS :'
    c:take()

    -- in use: a replacement of ten characters and a number
    c:recv ':srv 433 * averylongnick :Nickname is already in use'
    local sent = c:take()
    T.ok(sent[1]:match '^NICK averylongn%-%d%d%d%d%d$', 'in use: ' .. sent[1])

    -- erroneous: no replacement, and no reconnect
    c:recv ':srv 432 * averylongnick :Erroneous Nickname'
    T.eq(c:take(), {}, 'no NICK')
    T.ok(c.closed, 'connection closed')
    T.eq(rec().phase, 'idle', 'idle')
    T.eq(rec().target, 'idle', 'staying disconnected')
    T.eq(rec().reconnect_timer, nil, 'no reconnect')
    local lines = T.log_lines 'irc'
    T.ok(lines[#lines]:find('identity.nick: the server refuses averylongnick: Erroneous Nickname', 1, true),
        lines[#lines])
end)

T.case('a /nick refused as erroneous during registration is forgotten', function()
    local fake = boot {network('test')}
    T.require 'hub.net.intent'.of(rec()).nick = 'bad!'
    local c = fake.last()
    c:con()
    T.eq(c:take()[2], 'NICK bad!', 'registering with it')
    c:recv ':srv CAP * LS :'
    c:recv ':srv 432 * bad! :Erroneous Nickname'
    T.eq(rec().intent.nick, nil, 'the next connection tries the configured nick')
    local lines = T.log_lines 'irc'
    T.ok(lines[#lines]:find('/nick: the server refuses bad!', 1, true), lines[#lines])
end)

T.case('a file secret drops its final line break; one inside stops registration', function()
    local dir = os.tmpname()
    local function connect(text)
        assert(require 'pl.file'.write(dir, text))
        local fake = boot {network('test', {registration = {password = {file = dir}}})}
        local c = fake.last()
        c:con()
        return c
    end

    local c = connect 'hunter2\n'
    T.eq(c:take(), {'CAP LS 302', 'PASS hunter2', 'NICK me', 'USER me 0 * me'}, 'PASS without the line break')

    c = connect 'hunter2\nmore\n'
    T.eq(c:take(), {}, 'nothing sent')
    T.eq(rec().target, 'idle', 'staying disconnected')
    local lines = T.log_lines 'irc'
    T.ok(lines[#lines]:find('registration.password', 1, true), lines[#lines])
    os.remove(dir)
end)

-- Drop the connection, reconnect and register; returns the JOIN lines
local function rejoined(fake, c)
    c:finish 'gone'
    fire_reconnect 'test'
    c = fake.last()
    register(c)
    local joins = {}
    for _, line in ipairs(c:take()) do
        if line:match '^JOIN ' then table.insert(joins, line) end
    end
    return joins
end

T.case('a wanted channel without a key of its own rejoins with the configured one', function()
    local fake = boot {network('test', {buffers = {{name = '#k', key = 'cfgkey'}}})}
    local c = fake.last()
    register(c)
    c:recv ':me!u@h JOIN #k'
    T.eq(rejoined(fake, c), {'JOIN #k cfgkey'}, 'the configured key')
end)

T.case('a channel rejoins as the server last named it', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c)
    c:recv ':me!u@h JOIN #Chan'
    c:recv ':me!u@h JOIN #chan'
    T.eq(rejoined(fake, c), {'JOIN #chan'}, 'its latest name')
end)

T.case('a key sent with a JOIN serves that JOIN only', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c)
    local send = T.require 'hub.net.send'
    send.send('test', 'JOIN', '#k', 'k1')
    c:recv ':me!u@h JOIN #k'
    c:recv ':me!u@h PART #k'
    send.send('test', 'JOIN', '#k')
    c:recv ':me!u@h JOIN #k'
    T.eq(rejoined(fake, c), {'JOIN #k'}, 'no key left over from the first')
end)

T.case('a /nick while the MOTD arrives is the user\'s, not a configuration error', function()
    local fake = boot {network('test')}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :'
    c:recv ':srv 001 me :Welcome'
    c:take()
    T.command 'nick 1bad'
    c:recv ':srv 432 me 1bad :Erroneous Nickname'
    T.eq(rec().target, 'connected', 'still wanted')
    T.eq(rec().intent.nick, nil, '/nick forgotten')
    T.command 'nick taken'
    c:recv ':srv 433 me taken :Nickname is already in use'
    T.eq(c:take(), {'NICK 1bad', 'NICK taken'}, 'no random replacement')
    T.eq(rec().irc.recover_nick, 'taken', 'waited for')
    c:recv ':srv 376 me :End of MOTD'
    T.eq(rec().phase, 'connected', 'registered')
end)

T.case('SASL that cannot run says why', function()
    local function try(ls)
        local fake = boot {network('test', {sasl = {
            automatic = {'x'},
            credentials = {{name = 'x', mechanism = 'EXTERNAL'}},
        }})}
        local c = fake.last()
        c:con()
        c:recv(':srv CAP * LS :' .. ls)
        if ls ~= '' then c:recv(':srv CAP me ACK :sasl') end
        local lines = T.log_lines 'sasl'
        return table.concat(lines, '\n')
    end
    T.ok(try '':find('the server offers no SASL', 1, true), 'no sasl')
    local lines = try 'sasl=PLAIN,SCRAM-SHA-256'
    T.ok(lines:find('the server offers PLAIN, SCRAM-SHA-256, not EXTERNAL', 1, true), lines)
    T.ok(lines:find('no credential succeeded', 1, true), lines)
end)

T.case('secrets come from a command or a prompt', function()
    local prompts = {}
    local fake = boot {network('test', {
        registration = {password = {command = 'printf', arguments = {'s3cret\nignored'}}},
        oper = {automatic = {'password'},
            credentials = {{mechanism = 'password', username = 'op', password = {prompt = 'oper password'}}}},
    })}
    T.eq(fake.last(), nil, 'no connection while the command runs')
    local c = T.wait_until(fake.last, 'a connection once the command ran')
    c:con()
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

T.case('a secret command that fails is logged; PASS takes registration.username', function()
    local fake = boot {network('test', {registration = {username = 'acct',
        password = {command = 'sh', arguments = {'-c', 'echo pw'}}}})}
    local c = T.wait_until(fake.last, 'a connection')
    c:con()
    T.eq(c:take()[2], 'PASS acct:pw', 'username:password')

    fake = boot {network('test', {registration = {
        password = {command = 'sh', arguments = {'-c', 'echo broken >&2; exit 3'}}}})}
    c = T.wait_until(fake.last, 'a connection, the password having failed')
    c:con()
    T.eq(c:take(), {'CAP LS 302', 'NICK me', 'USER me 0 * me'}, 'registered without PASS')
    T.ok(table.concat(T.log_lines 'irc', '\n'):find('Password resolution failed: command failed (3): broken', 1, true),
        'and why')
end)

T.run()
