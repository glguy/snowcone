-- Capability negotiation (net/cap.lua) and the capabilities the model
-- keeps (net/irc.lua).
--
-- Run with:  snowcone tests/hub/test-cap.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local N = dofile(here .. '/netlib.lua')(T)
local network, boot, rec, register, requester = N.network, N.boot, N.rec, N.register, N.requester

local sasl_plain <const> = {
    automatic = {'PLAIN'},
    credentials = {{mechanism = 'PLAIN', username = 'u', password = 'p'}},
}

-- The names a list of sent lines requested with CAP REQ, sorted
local function requested(lines)
    local names = {}
    for _, line in ipairs(lines) do
        local req = line:match '^CAP REQ :?(.*)$'
        for name in (req or ''):gmatch '%S+' do table.insert(names, name) end
    end
    table.sort(names)
    return names
end

-- Connect and answer CAP LS with caps; returns the connection and what
-- it sent in reply
local function offer(extra, caps)
    local fake = T.boot_networks {T.network('test', extra)}
    local c = fake.last()
    c:con()
    c:take()
    c:recv(':srv CAP * LS :' .. caps)
    return c, c:take()
end

-- Written out, not read from net/irc.lua, so that dropping one there fails
local default_caps <const> = {
    'account-notify', 'account-tag', 'away-notify', 'batch', 'cap-notify', 'chghost',
    'draft/chathistory', 'echo-message', 'extended-join', 'extended-monitor', 'invite-notify',
    'labeled-response', 'message-tags', 'multi-prefix', 'sasl', 'server-time', 'setname',
    'soju.im/bouncer-networks', 'soju.im/bouncer-networks-notify', 'solanum.chat/identify-msg',
    'solanum.chat/oper', 'solanum.chat/realhost',
}

T.case('every supported capability the server offers is requested, and no other', function()
    local _, sent = offer(nil, table.concat(default_caps, ' ') .. ' draft/event-playback unknown-cap')
    T.eq(requested(sent), default_caps, 'the whole default list, and not event-playback')
end)

T.case('registration.capabilities adds names and removes them with -', function()
    local _, sent = offer({registration = {capabilities = {'-away-notify', 'draft/extra'}}},
        'away-notify draft/extra multi-prefix')
    T.eq(requested(sent), {'draft/extra', 'multi-prefix'}, 'away-notify left out, draft/extra in')
end)

T.case('a request too long for one line goes out as lines that fit', function()
    local names = {}
    for i = 1, 6 do names[i] = 'x-' .. string.rep(string.char(96 + i), 98) end
    local c, sent = offer({registration = {capabilities = names}}, table.concat(names, ' '))
    local reqs = {}
    for _, line in ipairs(sent) do
        if line:find '^CAP REQ' then
            table.insert(reqs, line)
            T.ok(#line + 2 <= 512, 'fits: ' .. #line + 2)
        end
    end
    T.eq(#reqs, 2, 'two lines')
    table.sort(names)
    T.eq(requested(sent), names, 'all of them')
    for _, line in ipairs(reqs) do
        c:recv(':srv CAP me ACK :' .. line:match '^CAP REQ :?(.*)$')
    end
    T.eq(c:take(), {'CAP END'}, 'ended once both are acknowledged')
end)

T.case('a NAK ends the wait, and leaves the capabilities off', function()
    local c, sent = offer(nil, 'multi-prefix away-notify')
    T.eq(requested(sent), {'away-notify', 'multi-prefix'}, 'requested')
    c:recv ':srv CAP * NAK :away-notify multi-prefix'
    T.eq(c:take(), {'CAP END'}, 'negotiation ends')
    T.eq(rec().irc.caps_enabled, {}, 'none enabled')
end)

T.case('CAP DEL forgets the capability and what it kept current', function()
    local fake = T.boot_networks {T.network('test')}
    local c = fake.last()
    T.register(c, {caps = 'sasl=PLAIN away-notify'})
    local irc = rec().irc
    T.eq(irc.caps_enabled, {sasl = true, ['away-notify'] = true}, 'enabled')
    c:recv ':me!u@h JOIN #c'
    c:recv ':alice!u@h JOIN #c'
    c:recv ':alice!u@h AWAY :gone'
    T.eq(irc.users.ALICE.away, 'gone', 'away known')

    c:recv ':srv CAP me ACK :-away-notify'
    T.eq(irc.users.ALICE.away, nil, 'unknown once turned off')
    c:recv ':srv CAP me ACK :away-notify'
    c:recv ':alice!u@h AWAY :gone again'
    T.eq(irc.users.ALICE.away, 'gone again', 'known again')
    c:recv ':srv CAP me DEL :away-notify'
    T.eq(irc.users.ALICE.away, nil, 'unknown without away-notify')
    c:recv ':srv CAP me DEL :sasl'
    T.eq({irc.caps_available.sasl, irc.caps_enabled.sasl, irc.sasl_mechs}, {nil, nil, nil}, 'sasl forgotten')
end)

T.case('credentials the server had no SASL for wait for CAP NEW sasl', function()
    local fake = T.boot_networks {T.network('test', {sasl = sasl_plain})}
    local c = fake.last()
    T.register(c)
    c:take()
    c:recv ':srv CAP me NEW :sasl=PLAIN'
    T.eq(c:take(), {'CAP REQ sasl'}, 'requested when offered')
    c:recv ':srv CAP me ACK :sasl'
    T.eq(c:take(), {'AUTHENTICATE PLAIN'}, 'and used')
end)

T.case('credentials are used once: a later CAP NEW sasl does not log in again', function()
    local fake = T.boot_networks {T.network('test', {sasl = sasl_plain})}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :sasl=PLAIN'
    c:recv ':srv CAP me ACK :sasl'
    c:recv 'AUTHENTICATE +'
    c:recv ':srv 900 me me!u@h u :You are now logged in as u'
    c:recv ':srv 903 me :SASL authentication successful'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 376 me :End of MOTD'
    c:take()
    c:recv ':srv CAP me DEL :sasl'
    c:recv ':srv CAP me NEW :sasl=PLAIN'
    T.eq(c:take(), {'CAP REQ sasl'}, 'requested again')
    c:recv ':srv CAP me ACK :sasl'
    T.eq(c:take(), {}, 'no second login')
end)

T.case('CAP DEL between the welcome and the end of MOTD drops what needed it', function()
    local fake = boot {network('test')}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :batch echo-message labeled-response'
    c:recv ':srv CAP me ACK :batch echo-message labeled-response'
    c:recv ':srv 001 me :Welcome'
    c:take()
    c:recv ':srv CAP me DEL :labeled-response'
    T.eq(c:take(), {'CAP REQ -echo-message'}, 'echo-message turned off')
    c:recv ':srv CAP me NEW :multi-prefix'
    c:recv ':srv CAP me ACK :-echo-message'
    T.eq(c:take(), {'CAP REQ multi-prefix'}, 'a new cap requested')
end)

T.case('a CAP REQ sent by hand takes effect when acked', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c)
    c:take()
    c:recv ':srv CAP me ACK :batch labeled-response'
    T.eq(rec().irc.caps_enabled['labeled-response'], true, 'enabled')
    requester({401}, 1000, 'WHOIS', 'x')
    T.eq(c:take(), {'@label=sc1 WHOIS x'}, 'requests are labeled')
    c:recv '@label=sc1 :srv ACK'
    c:recv ':srv CAP me ACK :-labeled-response'
    T.eq(rec().irc.caps_enabled['labeled-response'], nil, 'disabled')
end)

T.case('echo-message is requested only with labeled-response, and dropped without it', function()
    local fake = boot {network('test')}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :echo-message multi-prefix'
    T.eq(c:take(), {'CAP LS 302', 'NICK me', 'USER me 0 * me', 'CAP REQ multi-prefix'}, 'not alone')
    c:recv ':srv CAP me ACK :multi-prefix'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 376 me :End of MOTD'
    c:take()

    c:recv ':srv CAP me NEW :batch labeled-response echo-message'
    T.eq(c:take(), {'CAP REQ :batch echo-message labeled-response'}, 'with what it needs')
    c:recv ':srv CAP me ACK :batch echo-message labeled-response'

    T.require 'hub.net.send'.send('test', 'PRIVMSG', '#c', 'hi')
    T.eq(c:take(), {'@label=sc1 PRIVMSG #c hi'}, 'chat lines are labeled')

    c:recv ':srv CAP me DEL :labeled-response'
    T.eq(c:take(), {'CAP REQ -echo-message'}, 'turned off with labeled-response gone')
    c:recv ':srv CAP me ACK :-echo-message'
    T.eq(rec().irc.caps_enabled['echo-message'], nil, 'off')
    T.eq(next(HUB.tasks), nil, 'no tasks left')
end)

T.run()
