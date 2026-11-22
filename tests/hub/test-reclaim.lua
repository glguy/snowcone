-- Taking back the wanted nick (net/reclaim.lua), and the /nick that
-- declares it.
--
-- Run with:  snowcone tests/hub/test-reclaim.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local N = dofile(here .. '/netlib.lua')(T)
local network, boot, rec, record, register, stop_clock = N.network, N.boot, N.rec, N.record, N.register, N.stop_clock

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

T.case('nick in use while SASL is under way', function()
    local fake = boot {network('test', {
        sasl = {
            automatic = {'PLAIN'},
            credentials = {{mechanism = 'PLAIN', username = 'u', password = 'p'}},
        },
    })}
    local c = fake.last()
    c:con()
    c:take()
    c:recv ':srv CAP * LS :sasl=PLAIN'
    T.eq(c:take(), {'CAP REQ sasl'}, 'request')
    c:recv ':srv CAP me ACK :sasl'
    T.eq(c:take(), {'AUTHENTICATE PLAIN'}, 'mechanism')

    c:recv ':srv 433 * me :Nickname is already in use'
    local sent = c:take()
    T.eq(#sent, 1, 'one reply')
    local temp = T.ok(sent[1]:match '^NICK (me%-%d%d%d%d%d)$', 'random nick: ' .. sent[1])
    T.eq(rec().irc.recover_nick, 'me', 'the wanted nick is reclaimed later')

    c:recv 'AUTHENTICATE +'
    T.eq(c:take(), {'AUTHENTICATE ' .. mybase64.to_base64 '\0u\0p'}, 'SASL carries on')
    c:recv(':srv 903 ' .. temp .. ' :SASL authentication successful')
    T.eq(c:take(), {'CAP END'}, 'end of negotiation')

    c:recv(':srv 001 ' .. temp .. ' :Welcome')
    T.eq(rec().irc.nick, temp, 'registered with the replacement')
end)

T.case('the wanted nick is reclaimed in the casemapping the server announces', function()
    local fake = boot {network('test', {identity = {nick = 'me{x}'}})}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :'
    c:recv ':srv 433 * me{x} :Nickname is already in use'
    local temp = c:take()[2]:match '^NICK (.*)$'
    c:recv(':srv 001 ' .. temp .. ' :Welcome')
    c:recv(':srv 005 ' .. temp .. ' CASEMAPPING=ascii MONITOR=100 :are supported')
    c:recv(':srv 376 ' .. temp .. ' :End of MOTD')
    c:take()
    c:recv(':srv 731 ' .. temp .. ' :ME{X}')
    T.eq(c:take(), {'NICK me{x}'}, 'reclaimed')
end)

T.case('/nick declares the wanted nick, here and on later connections', function()
    local fake = boot {network('test')}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :'
    c:recv ':srv 433 * me :Nickname is already in use'
    local temp = c:take()[2]:match '^NICK (.*)$'
    c:recv(':srv 001 ' .. temp .. ' :Welcome')
    c:recv(':srv 005 ' .. temp .. ' MONITOR=100 :are supported')
    c:recv(':srv 376 ' .. temp .. ' :End of MOTD')
    T.eq(c:take(), {'MONITOR + me', 'MODE ' .. temp}, 'waiting for me')

    T.command 'nick other'
    T.eq(c:take(), {'NICK other'}, 'me no longer wanted')
    c:recv(':' .. temp .. '!u@h NICK other')
    c:recv ':srv 731 other :me'
    T.eq(c:take(), {'MONITOR - me'}, 'me not reclaimed, and unwatched once answered')

    -- taken: waited for
    T.command 'nick third'
    c:recv ':srv 433 other third :Nickname is already in use'
    T.eq(c:take(), {'NICK third', 'MONITOR + third'}, 'third wanted')
    c:recv ':srv 731 other :third'
    T.eq(c:take(), {'NICK third'}, 'and reclaimed')
    c:recv ':other!u@h NICK third'
    T.eq(c:take(), {'MONITOR - third'}, 'done waiting')

    -- the next connection registers with it
    T.require 'hub.net.manager'.reconnect 'test'
    c = fake.last()
    c:con()
    T.eq(c:take(), {'CAP LS 302', 'NICK third', 'USER me 0 * me'}, 'registering as third')

    -- until the configured nick changes
    T.ok(T.reload {config = {networks = {network('test', {identity = {nick = 'fourth'}})}}}, 'reload')
    T.eq(rec().intent.nick, nil, 'the configured nick wanted again')
end)

T.case('the wanted nick is reclaimed when its holder changes nick', function()
    local fake = boot {network('test', {reclaim_nick = true})}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :'
    c:recv ':srv 433 * me :Nickname is already in use'
    local temp = c:take()[5]:match '^NICK (.*)$'
    c:recv(':srv 001 ' .. temp .. ' :Welcome')
    c:recv(':srv 005 ' .. temp .. ' CHANTYPES=# :are supported')
    c:recv(':srv 376 ' .. temp .. ' :End of MOTD')
    c:recv(':' .. temp .. '!u@h JOIN #c')
    c:recv ':srv 353 x = #c :me'
    c:take()
    c:recv ':me!u@h NICK ME'
    T.eq(c:take(), {}, 'not for a change of case')
    c:recv ':ME!u@h NICK other'
    T.eq(c:take(), {'NICK me'}, 'reclaimed')
end)

-- Registered on a random nick, with MONITOR, the wanted one taken
local function on_temp_nick(c)
    c:con()
    c:take()
    c:recv ':srv CAP * LS :'
    c:recv ':srv 433 * me :Nickname is already in use'
    local temp = T.ok(c:take()[2]:match '^NICK (me%-%d+)$', 'random nick')
    c:recv(':srv 001 ' .. temp .. ' :Welcome')
    c:recv(':srv 005 ' .. temp .. ' CHANTYPES=# MONITOR=100 :are supported')
    c:recv(':srv 376 ' .. temp .. ' :End of MOTD')
    c:take()
    return temp
end

-- The nick recovery task, or nil
local function reclaim_task()
    for _, t in pairs(HUB.tasks) do
        if t.name == 'nick recovery' then return t end
    end
end

-- End the nick recovery task's wait now instead of waiting for its timer
local function fire_reclaim_timeout()
    local t = T.ok(reclaim_task(), 'reclaim task')
    T.ok(t.timer, 'reclaim task holds back')
    T.require 'hub.runtime.timer'.cancel(t.timer)
    HUB.current.routes['task.wake'](t.id, t.seq)
end

T.case('a held nick is tried again later, waiting longer each time', function()
    local fake = boot {network('test')}
    local c = fake.last()
    local temp = on_temp_nick(c)
    stop_clock()
    T.ok(reclaim_task(), 'reclaiming')
    c:recv(':srv 731 ' .. temp .. ' :me')
    T.eq(c:take(), {'NICK me'}, 'tried')
    c:recv(':srv 437 ' .. temp .. ' me :Nick/channel is temporarily unavailable')
    T.eq(rec().irc.reclaim.held_until - T.require 'hub.runtime.clock'.now(), 30, 'held 30 s')
    c:recv(':srv 731 ' .. temp .. ' :me')
    T.eq(c:take(), {}, 'nothing while held')
    fire_reclaim_timeout()
    T.eq(c:take(), {'NICK me'}, 'tried again')
    c:recv(':srv 437 ' .. temp .. ' me :Nick/channel is temporarily unavailable')
    T.eq(rec().irc.reclaim.held_until - T.require 'hub.runtime.clock'.now(), 60, 'then 60 s')
    fire_reclaim_timeout()
    T.eq(c:take(), {'NICK me'}, 'and again')
    c:recv(':' .. temp .. '!u@h NICK me')
    T.eq(c:take(), {'MONITOR - me'}, 'done')
    T.eq(reclaim_task(), nil, 'no task once the nick is ours')
end)

T.case('a nick change refused as too fast waits as long as the server says', function()
    local fake = boot {network('test')}
    local c = fake.last()
    local temp = on_temp_nick(c)
    local advance = stop_clock()
    c:recv(':srv 731 ' .. temp .. ' :me')
    T.eq(c:take(), {'NICK me'}, 'tried')
    c:recv(':srv 438 ' .. temp .. ' ' .. temp .. ' me :Nick change too fast. Please wait 20 seconds.')
    T.eq(rec().irc.reclaim.held_until - T.require 'hub.runtime.clock'.now(), 21, 'held past the wait')
    advance(5)
    T.eq(HUB.current.routes['net.reclaim_nick']('test'), false, 'a server notice waits too')
    fire_reclaim_timeout()
    T.eq(c:take(), {'NICK me'}, 'tried again')
end)

T.case('a nick the server changes is reclaimed', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c, 'me', 'CHANTYPES=# MONITOR=100')
    c:take()
    T.eq(reclaim_task(), nil, 'nothing to reclaim')
    c:recv ':srv 043 me 001AAAAAA :Nick collision, forcing nick change to your unique ID'
    c:recv ':me!u@h NICK 001AAAAAA'
    T.eq(c:take(), {'MONITOR + me'}, 'waiting for me')
    T.eq(rec().irc.recover_nick, 'me', 'reclaiming')
    c:recv ':srv 731 001AAAAAA :me'
    T.eq(c:take(), {'NICK me'}, 'reclaimed')
    c:recv ':001AAAAAA!u@h NICK me'
    T.eq(c:take(), {'MONITOR - me'}, 'done')

    -- a change we asked for is ours
    T.command 'quote NICK other'
    c:take()
    c:recv ':me!u@h NICK other'
    T.eq(c:take(), {}, 'not reclaimed')
    T.eq(rec().irc.recover_nick, nil, 'nothing to reclaim')
end)

T.case('a nick the server cuts to NICKLEN is the one wanted', function()
    local fake = boot {network('test', {identity = {nick = 'averyverylongnick'}})}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :'
    c:recv ':srv 001 averyvery :Welcome'
    c:recv ':srv 005 averyvery CHANTYPES=# MONITOR=100 NICKLEN=9 :are supported'
    c:recv ':srv 376 averyvery :End of MOTD'
    T.eq(rec().irc.recover_nick, nil, 'a configured nick cut by the server is ours')
    c:take()

    T.command 'nick anotherlongnick'
    c:recv ':averyvery!u@h NICK anotherlo'
    T.eq(c:take(), {'NICK anotherlongnick'}, 'not reclaimed')
    T.eq({rec().intent.nick, rec().irc.recover_nick}, {'anotherlo', nil}, 'wanted as cut')

    c:recv ':anotherlo!u@h NICK Guest1'
    T.eq(c:take(), {'MONITOR + anotherlo'}, 'reclaimed as cut')
end)

T.case('a welcome on another nick than asked reclaims the wanted one', function()
    local fake = boot {network('test')}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :'
    c:recv ':srv 001 me_ :Welcome'
    c:recv ':srv 005 me_ CHANTYPES=# MONITOR=100 :are supported'
    c:recv ':srv 376 me_ :End of MOTD'
    T.eq(rec().irc.recover_nick, 'me', 'reclaiming')
    local sent = c:take()
    local monitored = false
    for _, line in ipairs(sent) do monitored = monitored or line == 'MONITOR + me' end
    T.ok(monitored, 'watched: ' .. table.concat(sent, ' | '))
    c:recv ':srv 731 me_ :me'
    T.eq(c:take(), {'NICK me'}, 'reclaimed')
end)

T.case('behind a bouncer, its session\'s nick is left alone', function()
    local fake = boot {network('test')}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :soju.im/bouncer-networks'
    c:recv ':srv CAP me_ ACK :soju.im/bouncer-networks'
    c:recv ':srv 001 me_ :Welcome'
    c:recv ':srv 005 me_ CHANTYPES=# MONITOR=100 :are supported'
    c:recv ':srv 376 me_ :End of MOTD'
    T.eq(rec().irc.recover_nick, nil, 'the welcome nick kept')
    c:take()

    -- another client of the bouncer changes nick
    c:recv ':me_!u@h NICK other'
    T.eq(c:take(), {}, 'not undone')
    T.eq(rec().irc.recover_nick, nil, 'nothing to reclaim')

    -- our own /nick, refused for now, is still retried ...
    T.command 'nick mine'
    c:recv ':srv 433 other mine :Nickname is already in use'
    T.eq(c:take(), {'NICK mine', 'MONITOR + mine'}, 'waiting for mine')
    -- ... until another client picks a nick
    c:recv ':other!u@h NICK theirs'
    T.eq(c:take(), {}, 'no longer ours to reclaim')
    c:recv ':srv 731 theirs :mine'
    T.eq(c:take(), {'MONITOR - mine'}, 'unwatched once answered')
    T.eq(rec().irc.recover_nick, nil, 'stopped')
end)

T.case('a nick held during registration gets a temporary one, and is reclaimed', function()
    local fake = boot {network('test')}
    local c = fake.last()
    c:con()
    c:take()
    c:recv ':srv CAP * LS :'
    c:take()
    c:recv ':srv 437 * me :Nick/channel is temporarily unavailable'
    T.ok(c:take()[1]:match '^NICK me%-%d+$', 'a temporary nick')
    T.eq(rec().irc.recover_nick, 'me', 'the wanted one reclaimed later')
end)

T.case('without MONITOR, its holder quitting where we see it frees the nick', function()
    local fake = boot {network('test')}
    local c = fake.last()
    c:con()
    c:take()
    c:recv ':srv CAP * LS :'
    c:recv ':srv 433 * me :Nickname is already in use'
    local temp = c:take()[2]:match '^NICK (.*)$'
    c:recv(':srv 001 ' .. temp .. ' :Welcome')
    c:recv(':srv 376 ' .. temp .. ' :End of MOTD')
    c:recv(':' .. temp .. '!u@h JOIN #c')
    c:recv ':srv 353 x = #c :me'
    c:take()
    c:recv ':me!u@h QUIT :Ping timeout'
    T.eq(c:take(), {'NICK me'}, 'reclaimed')
end)

T.case('with reclaim_nick off, the wanted nick is remembered but never taken', function()
    local fake = boot {network('test', {reclaim_nick = false})}
    local c = fake.last()
    c:con()
    c:take()
    c:recv ':srv CAP * LS :'
    c:recv ':srv 433 * me :Nickname is already in use'
    local temp = c:take()[2]:match '^NICK (.*)$'
    c:recv(':srv 001 ' .. temp .. ' :Welcome')
    c:recv(':srv 005 ' .. temp .. ' CHANTYPES=# MONITOR=100 :are supported')
    c:recv(':srv 376 ' .. temp .. ' :End of MOTD')
    T.eq(c:take(), {'MODE ' .. temp}, 'no MONITOR')
    T.eq({rec().irc.recover_nick, reclaim_task()}, {'me', nil}, 'remembered, with no task')
    c:recv(':srv 731 ' .. temp .. ' :me')
    T.eq(HUB.current.routes['net.reclaim_nick']('test'), false, 'a server notice takes nothing')
    T.eq(c:take(), {}, 'never taken')
end)

T.case('a /nick held or refused as too fast is tried again later', function()
    local fake = boot {network('test')}
    local c = fake.last()
    local temp = on_temp_nick(c)
    stop_clock()
    T.command 'nick other'
    c:take()
    c:recv(':srv 437 ' .. temp .. ' other :Nick/channel is temporarily unavailable')
    T.eq(c:take(), {'MONITOR + other'}, 'held: watched')
    T.ok(rec().irc.reclaim.held_until, 'and held back')
    fire_reclaim_timeout()
    T.eq(c:take(), {'NICK other'}, 'tried again')

    T.command 'nick third'
    c:take()
    c:recv(':srv 438 ' .. temp .. ' ' .. temp .. ' third :Nick change too fast. Please wait 20 seconds.')
    T.eq(c:take(), {'MONITOR + third'}, 'too fast: watched')
    T.eq(rec().irc.reclaim.held_until - T.require 'hub.runtime.clock'.now(), 21, 'held past the wait')
end)

T.case('a nick refused as erroneous while reclaiming is reclaimed no more', function()
    local fake = boot {network('test')}
    local c = fake.last()
    local temp = on_temp_nick(c)
    c:recv(':srv 731 ' .. temp .. ' :me')
    T.eq(c:take(), {'NICK me'}, 'tried')
    c:recv(':srv 432 ' .. temp .. ' me :Erroneous Nickname')
    T.eq(c:take(), {'MONITOR - me'}, 'unwatched')
    T.eq({rec().irc.recover_nick, reclaim_task()}, {nil, nil}, 'not reclaimed')
end)

T.case('behind ZNC, too, the welcome nick is the session\'s', function()
    local fake = boot {network('test')}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :znc.in/self-message'
    c:recv ':srv 001 me_ :Welcome'
    c:recv ':srv 005 me_ CHANTYPES=# MONITOR=100 :are supported'
    c:recv ':srv 376 me_ :End of MOTD'
    T.eq(rec().irc.recover_nick, nil, 'kept')
end)

T.case('a refused /nick leaves the wanted nick reclaimed', function()
    local fake = boot {network('test')}
    local c = fake.last()
    local temp = on_temp_nick(c)

    -- erroneous: the configured nick is wanted again
    T.command 'nick 1bad'
    T.eq(c:take(), {'NICK 1bad'}, 'me no longer wanted, its MONITOR + unanswered')
    c:recv(':srv 432 ' .. temp .. ' 1bad :Erroneous Nickname')
    T.eq(rec().intent.nick, nil, '/nick forgotten')
    T.eq(c:take(), {}, 'me wanted again, still asked for')
    T.eq(T.require 'hub.net.monitor'.reasons(rec().irc, 'me'), {reclaim = true}, 'by the reclaim')

    -- banned in a channel: tried again later
    T.command 'nick other'
    c:take()
    c:recv(':srv 435 ' .. temp .. ' other #c :Cannot change nickname because you are banned'
        .. ' or quieted while in this channel.')
    T.eq(rec().intent.nick, 'other', 'still wanted')
    T.eq(rec().irc.recover_nick, 'other', 'reclaimed')
    T.eq(c:take(), {'MONITOR + other'}, 'watched')
    T.ok(rec().irc.reclaim.held_until, 'held back')
    c:recv(':srv 731 ' .. temp .. ' :other')
    T.eq(c:take(), {}, 'not while held')
    fire_reclaim_timeout()
    T.eq(c:take(), {'NICK other'}, 'tried again')
end)

T.case('one nick coming free sends one NICK', function()
    local fake = boot {network('test')}
    local c = fake.last()
    local temp = on_temp_nick(c)
    c:recv(':' .. temp .. '!u@h JOIN #c')
    c:recv ':srv 353 x = #c :me'
    c:take()
    c:recv ':me!u@h QUIT :bye'
    c:recv(':srv 731 ' .. temp .. ' :me')
    T.eq(c:take(), {'NICK me'}, 'once')
    c:recv(':srv 433 ' .. temp .. ' me :Nickname is already in use')
    c:recv(':srv 731 ' .. temp .. ' :me')
    T.eq(c:take(), {'NICK me'}, 'again after the reply')
end)

-- MONITOR shared with chat's private buffers (net/monitor.lua)

T.case('a reclaim and a private buffer watch one nick, which stays watched while either does', function()
    local fake = boot {network('test', {features = {'chat'}})}
    local c = fake.last()
    register(c, 'me', 'CHANTYPES=# MONITOR=100')
    c:take()
    stop_clock()
    T.command 'talk other'
    T.eq(c:take(), {'MONITOR + other'}, 'the buffer watches other')
    c:recv ':srv 731 me :other'

    -- held: the reclaim joins the buffer's MONITOR, which gets no new
    -- reply, and the refusal that started it holds it back
    T.command 'nick other'
    c:recv ':srv 437 me other :Nick/channel is temporarily unavailable'
    T.eq(c:take(), {'NICK other'}, 'no second MONITOR +, and no NICK while held')
    T.eq(T.require 'hub.net.monitor'.reasons(rec().irc, 'other'), {chat = true, reclaim = true}, 'both watch it')
    fire_reclaim_timeout()
    T.eq(c:take(), {'NICK other'}, 'tried once the hold is over')

    c:recv ':me!u@h NICK other'
    T.eq(c:take(), {}, 'ours: the buffer still watches it')
    T.command 'close other'
    T.eq(c:take(), {'MONITOR - other'}, 'unwatched with its last reason')
end)

T.case('a reclaim stopped before its MONITOR reply leaves no stale entry behind', function()
    local fake = boot {network('test', {features = {'chat'}})}
    local c = fake.last()
    local temp = on_temp_nick(c)
    T.command 'nick other'
    c:recv(':' .. temp .. '!u@h NICK other')
    T.eq(c:take(), {'NICK other'}, 'me no longer wanted, its MONITOR + unanswered')
    c:recv ':srv 731 other :me'
    T.eq(c:take(), {'MONITOR - me'}, 'unwatched on the reply')
    local irc_model = T.require 'hub.net.irc'
    T.eq(irc_model.get_monitor(rec().irc, 'me'), nil, 'not in the model')
    T.command 'talk me'
    T.eq(c:take(), {'MONITOR + me'}, 'a buffer for it asks again')
end)

T.case('a reconnection watches the open buffers\' nicks again, with the reclaim', function()
    local fake = boot {network('test', {features = {'chat'}})}
    local c = fake.last()
    register(c, 'me', 'CHANTYPES=# MONITOR=100')
    T.command 'talk bob'
    T.command 'talk me_away'
    c:take()

    T.require 'hub.net.manager'.reconnect 'test'
    c = fake.last()
    c:con()
    c:take()
    c:recv ':srv CAP * LS :'
    c:recv ':srv 433 * me :Nickname is already in use'
    local temp = T.ok(c:take()[2]:match '^NICK (me%-%d+)$', 'random nick')
    T.command 'talk me'
    c:recv(':srv 001 ' .. temp .. ' :Welcome')
    c:recv(':srv 005 ' .. temp .. ' CHANTYPES=# MONITOR=100 :are supported')
    c:recv(':srv 376 ' .. temp .. ' :End of MOTD')
    local plus = {}
    for _, line in ipairs(c:take()) do
        local list = line:match '^MONITOR %+ (.*)$'
        if list then table.insert(plus, list) end
    end
    T.eq(#plus, 1, 'one MONITOR +: ' .. table.concat(plus, ' | '))
    local nicks = {}
    for nick in plus[1]:gmatch '[^,]+' do nicks[nick] = true end
    T.eq(nicks, {bob = true, me_away = true, me = true}, 'every private buffer, and the wanted nick')
    T.eq(T.require 'hub.net.monitor'.reasons(rec().irc, 'me'), {chat = true, reclaim = true}, 'me for both')

    c:recv(':srv 731 ' .. temp .. ' :me')
    T.eq(c:take(), {'NICK me'}, 'the one reply reaches the reclaim')
end)

T.run()
