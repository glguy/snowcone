-- Sending IRC lines (net/send.lua): what a line may hold, and /raw.
--
-- Run with:  snowcone tests/hub/test-send.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')

-- A registered network; returns its connection and net/send.lua
local function registered(extra, isupport)
    local fake = T.boot_networks {T.network('test', extra)}
    local c = fake.last()
    T.register(c, {isupport = isupport})
    return c, T.require 'hub.net.send'
end

local function rec()
    return HUB.state.nets.test
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

T.run()
