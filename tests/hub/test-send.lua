-- Sending IRC lines (net/send.lua): what a line may hold, /raw, tags,
-- and the queue a rate limit holds lines in.
--
-- Run with:  snowcone tests/hub/test-send.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local N = dofile(here .. '/netlib.lua')(T)
local network, boot, rec, manager, record, register = N.network, N.boot, N.rec, N.manager, N.record, N.register
local stop_clock, register_labeled = N.stop_clock, N.register_labeled

-- A registered network; returns its connection and net/send.lua
local function registered(extra, isupport)
    local fake = T.boot_networks {T.network('test', extra)}
    local c = fake.last()
    T.register(c, {isupport = isupport})
    return c, T.require 'hub.net.send'
end

-- The newest line in the network's console log
local function newest_console()
    for msg in T.require 'hub.lib.OrderedMap'.each(rec().console) do -- luacheck: ignore 512
        return msg
    end
end

T.case('no argument may hold CR, LF or NUL, which would end the line', function()
    local c, send = registered()
    for _, bad in ipairs {'a\rb', 'a\nb', 'a\0b'} do
        T.raises('prohibited character in command argument', send.send, 'test', 'PRIVMSG', '#c', bad)
        T.raises('prohibited character in command argument', send.send, 'test', 'PRIVMSG', bad, 'text')
    end
    T.raises('bad command', send.send, 'test', 'PRIVMSG\r\nQUIT', 'x')
    T.eq(c:take(), {}, 'nothing sent')
end)

T.case('only the last argument may be empty, start with a colon or hold a space', function()
    local c, send = registered()
    send.send('test', 'PRIVMSG', '#c', '')
    send.send('test', 'PRIVMSG', '#c', ':-)')
    send.send('test', 'PRIVMSG', '#c', 'two words')
    send.send('test', 'MODE', '#c', '+o', 'nick')
    T.eq(c:take(), {'PRIVMSG #c :', 'PRIVMSG #c ::-)', 'PRIVMSG #c :two words', 'MODE #c +o nick'},
        'the last one takes a colon when it needs one')
    for _, bad in ipairs {'', ':x', 'a b'} do
        T.raises("an argument before the last can't", send.send, 'test', 'PRIVMSG', bad, 'text')
    end
    T.eq(c:take(), {}, 'nothing sent')
end)

T.case('a line must fit the server\'s LINELEN, and every argument be given', function()
    local c, send = registered(nil, 'CHANTYPES=# LINELEN=40')
    send.send('test', 'PRIVMSG', '#c', string.rep('x', 27)) -- 40 bytes with CRLF
    T.eq(#c:take(), 1, 'a line that just fits')
    T.raises('message too long: 41', send.send, 'test', 'PRIVMSG', '#c', string.rep('x', 28))
    T.raises('missing argument 2 to PRIVMSG', send.send, 'test', 'PRIVMSG', '#c', nil, 'x')
    T.eq(c:take(), {}, 'nothing sent')
end)

T.case('a secret argument is masked where the line is recorded; a plain one is not', function()
    local c, send = registered()
    send.send('test', 'PASS', {content = 'hunter2', secret = true})
    T.eq(c:take(), {'PASS hunter2'}, 'sent as given')
    T.eq(newest_console()[1], '\x0304*', 'masked in the console')
    send.send('test', 'PRIVMSG', '#c', {content = 'shown'})
    c:take()
    T.eq(newest_console()[2], 'shown', 'a table without secret is shown')
end)

T.case('/raw sends a line as typed, recorded as typed', function()
    local c = registered()
    T.command 'raw PRIVMSG #c :hello there'
    T.eq(c:take(), {'PRIVMSG #c :hello there'}, 'sent')
    local msg = newest_console()
    T.eq({msg.command, msg[1]}, {'RAW', 'PRIVMSG #c :hello there'}, 'recorded')
end)

T.case('/raw refuses CR, LF and NUL, and a line longer than the server takes', function()
    local c, send = registered(nil, 'CHANTYPES=# LINELEN=20')
    for _, bad in ipairs {'PING a\rQUIT', 'PING a\nQUIT', 'PING a\0'} do
        T.raises('prohibited character in raw line', send.raw, 'test', bad)
    end
    send.raw('test', '@tag=' .. string.rep('t', 50) .. ' PING :123456789012') -- 20 with CRLF
    T.eq(#c:take(), 1, 'a line that just fits; tags do not count')
    T.raises('line too long: 21', send.raw, 'test', 'PING :1234567890123')
    T.eq(c:take(), {}, 'nothing sent')
end)

T.case('/raw lines say what we want, as typed commands do', function()
    local c = registered()
    T.command 'raw JOIN #k :sekrit'
    c:recv ':me!u@h JOIN #k'
    T.eq(rec().intent.channels, {{name = '#k', key = 'sekrit'}}, 'the key it joined with')
    T.command 'raw AWAY :out to lunch'
    T.eq(rec().intent.away, 'out to lunch', 'away')
    T.command 'raw NICK other'
    c:take()
    c:recv ':me!u@h NICK other'
    T.eq(rec().irc.recover_nick, nil, 'a NICK we sent is ours, not one to undo')
end)

-- Run a network's pending send-queue drain now instead of waiting for its
-- timer
local function fire_drain(id)
    local r = rec(id)
    T.ok(r.sendq and r.sendq.timer, 'drain scheduled')
    T.require 'hub.runtime.timer'.cancel(r.sendq.timer)
    HUB.current.routes['net.send_drain'](r.id, r.attempt)
end

-- A registered network whose lines the rate limit paces from now on, with
-- the clock stopped
local function limited(limit)
    local fake = boot {network('test')}
    local c = fake.last()
    register(c)
    c:take()
    local advance = stop_clock()
    advance(100) -- a full burst
    rec().cfg.rate_limit = limit
    return c, advance, T.require 'hub.net.send'
end

T.case('a line typed as is may not be longer than the server takes', function()
    local fake = boot {network('test')}
    register(fake.last())
    local send = T.require 'hub.net.send'
    T.raises('line too long: 513', send.raw, 'test', 'PRIVMSG #c :' .. ('x'):rep(499))
    send.raw('test', '@label=x PRIVMSG #c :' .. ('x'):rep(498))
end)

T.case('a bare PING gets a PONG, and a command must be a word', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c)
    c:take()
    c:recv ':srv PING'
    T.eq(c:take(), {'PONG :'}, 'answered')
    local send = T.require 'hub.net.send'
    T.ok(not pcall(send.send, 'test', 'PRIVMSG x\r\nQUIT', 'y'), 'a command with a line break refused')
    T.ok(not pcall(send.send, 'test', 'PRIVMSG', nil, 'x'), 'a missing argument refused')
    T.eq(c:take(), {}, 'nothing sent')
end)

T.case('tags are escaped and not counted in the line length', function()
    local fake = boot {network('test')}
    local send = T.require 'hub.net.send'
    T.eq(send.tag_prefix {}, '', 'no tags')
    T.eq(send.tag_prefix {b = 'x y;z\\', a = ''}, '@a;b=x\\sy\\:z\\\\ ', 'escaped, in order')

    local c = fake.last()
    register_labeled(c)
    local long = string.rep('x', 512 - #'PRIVMSG #c \r\n')
    local task = T.require 'hub.runtime.task'
    task.spawn('long', {net = 'test'}, function(t)
        t:request({}, 1000, 'PRIVMSG', '#c', long)
    end)
    T.eq(c:take(), {'@label=sc1 PRIVMSG #c ' .. long}, 'a full line still goes')
    c:recv '@label=sc1 :srv ACK'
    T.eq(next(HUB.tasks), nil, 'answered')
end)

T.case('a rate limit sends a burst, then a line per interval', function()
    local c, advance, send = limited {burst = 3, interval = 2}
    local sent = record 'irc.sent'
    for i = 1, 5 do send.send('test', 'PRIVMSG', '#c', 'm' .. i) end
    T.eq(c:take(), {'PRIVMSG #c m1', 'PRIVMSG #c m2', 'PRIVMSG #c m3'}, 'the burst')
    T.eq(#sent, 5, 'every line reported at once')
    T.eq(sent[1].msg.delivery, nil, 'a line written at once has no delivery')
    T.eq(sent[4].msg.delivery, {state = 'queued'}, 'queued')
    T.ok(not send.ready('test'), 'not ready while lines wait')

    advance(1.5)
    fire_drain()
    T.eq(c:take(), {}, 'too early')
    advance(0.5)
    fire_drain()
    T.eq(c:take(), {'PRIVMSG #c m4'}, 'one interval later')
    T.eq(sent[4].msg.delivery, {state = 'sent', delay = 2}, 'sent after its wait')
    advance(2)
    fire_drain()
    T.eq(c:take(), {'PRIVMSG #c m5'}, 'and the next')
    T.eq({#rec().sendq.lines, rec().sendq.timer}, {0, nil}, 'nothing pending')

    rec().cfg.rate_limit = nil
    for i = 6, 9 do send.send('test', 'PRIVMSG', '#c', 'm' .. i) end
    T.eq(#c:take(), 4, 'no limit, no waiting')
end)

T.case('PONG goes ahead of queued lines and QUIT drops them', function()
    local c, advance, send = limited {burst = 1, interval = 10}
    local sent = record 'irc.sent'
    for i = 1, 3 do send.send('test', 'PRIVMSG', '#c', 'm' .. i) end
    T.eq(c:take(), {'PRIVMSG #c m1'}, 'the burst')
    c:recv 'PING :tok'
    advance(10)
    fire_drain()
    T.eq(c:take(), {'PONG tok'}, 'PONG first')
    advance(10)
    fire_drain()
    T.eq(c:take(), {'PRIVMSG #c m2'}, 'then the queue in order')

    manager().disconnect('test')
    T.eq(c:take(), {'QUIT snowcone'}, 'QUIT at once')
    T.eq(sent[3].msg.delivery.state, 'dropped', 'the line still queued is dropped')
    T.eq(rec().sendq, nil, 'queue gone')
end)

T.case('an ended connection marks its queued lines dropped', function()
    local c, _, send = limited {burst = 1, interval = 10}
    local sent = record 'irc.sent'
    for i = 1, 3 do send.send('test', 'PRIVMSG', '#c', 'm' .. i) end
    c:take()
    local drain = rec().sendq.timer
    c:finish 'reset'
    T.eq({sent[2].msg.delivery.state, sent[3].msg.delivery.state}, {'dropped', 'dropped'}, 'dropped')
    T.eq(rec().sendq, nil, 'queue gone')
    T.eq(T.require 'hub.runtime.resources'.get(drain), nil, 'drain timer canceled')
    local lines = T.log_lines 'irc'
    T.ok(lines[#lines - 2]:find('dropped 2 queued lines', 1, true), 'logged: ' .. lines[#lines - 2])
end)

T.case('the lag PING waits for the send queue to empty', function()
    local c, advance, send = limited {burst = 1, interval = 10}
    send.send('test', 'PRIVMSG', '#c', 'm1')
    send.send('test', 'PRIVMSG', '#c', 'm2')
    c:take()
    local now = T.require 'hub.runtime.clock'.now()
    rec().liveness = now -- not silent, just unmeasured
    manager().check_liveness(now)
    T.eq({#rec().sendq.lines, rec().lag_token}, {1, nil}, 'no PING behind the queue')
    advance(20)
    fire_drain()
    T.eq(c:take(), {'PRIVMSG #c m2'}, 'drained')
    rec().liveness = now + 20
    manager().check_liveness(now + 20)
    T.eq(c:take(), {}, 'nor while the burst is used up')
    advance(10)
    rec().liveness = now + 30
    manager().check_liveness(now + 30)
    local lines = c:take()
    T.eq(#lines, 1, 'one line')
    T.ok(lines[1]:find '^PING ', 'then the PING: ' .. lines[1])
end)

T.case('the drain timer writes queued lines', function()
    local fake = boot {network('test', {rate_limit = {burst = 1, interval = 0.02}})}
    local c = fake.last()
    register(c)
    local function drained()
        return not (rec().sendq and #rec().sendq.lines > 0)
    end
    T.wait_until(drained, 'registration drained')
    c:take()
    local send = T.require 'hub.net.send'
    for i = 1, 3 do send.send('test', 'PRIVMSG', '#c', 'm' .. i) end
    T.ok(not drained(), 'held back by the rate limit')
    T.wait_until(drained, 'the queue drained')
    T.eq(c:take(), {'PRIVMSG #c m1', 'PRIVMSG #c m2', 'PRIVMSG #c m3'}, 'all sent, in order')
end)

T.run()
