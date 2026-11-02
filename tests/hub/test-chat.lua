-- Chat buffers, routing, history, CTCP, notifications and the crypto
-- commands.
--
-- Run with:  snowcone tests/hub/test-chat.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local FakeTransport = dofile(here .. '/fake_transport.lua')
-- for the keymap, which Tab completion goes through
dofile(here .. '/fake_ncurses.lua').install()

local function boot(extra, global)
    local fake = FakeTransport.new()
    local net = {id = 'test', server = {host = 'test.example', port = 6667}, identity = {nick = 'me'}}
    for k, v in pairs(extra or {}) do net[k] = v end
    local config = {networks = {net}}
    for k, v in pairs(global or {}) do config[k] = v end
    T.boot {transport = fake, config = config}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :draft/chathistory'
    c:recv ':srv CAP me ACK :draft/chathistory'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 005 me CHANTYPES=# MONITOR=100 CHATHISTORY=50 STATUSMSG=@+ :are supported'
    c:recv ':srv 376 me :End of MOTD'
    c:take()
    return c, T.require 'hub.features.chat', fake
end

local function texts(buffer)
    local list = {}
    for msg in T.require 'hub.lib.OrderedMap'.reveach(buffer.messages) do
        table.insert(list, tostring(msg.command) .. ' ' .. table.concat(msg, ' '))
    end
    return list
end

T.case('buffers fold with the casemapping the server announces, before and after', function()
    local c, chat, fake = boot()
    local function keys()
        local list = {}
        for key in pairs(chat.get('test').buffers) do table.insert(list, key) end
        table.sort(list)
        return list
    end
    chat.open('test', '#a{b}')
    c:recv ':srv 005 me CASEMAPPING=ascii :are supported'
    c:recv ':me!u@h JOIN #a{b}'
    T.eq(keys(), {'#A{B}'}, 'one buffer for the channel')
    T.ok(chat.buffer('test', '#A{B}'), 'found in either case')
    T.eq(chat.buffer('test', '#a[b]'), nil, 'not a different channel')

    -- between connections the last casemapping still holds
    local manager = T.require 'hub.net.manager'
    manager.disconnect 'test'
    c:finish()
    chat.open('test', '#c{d}')
    T.ok(chat.buffer('test', '#C{D}'), 'ascii while disconnected')
    T.eq(chat.buffer('test', '#c[d]'), nil, 'not rfc1459')

    -- a coarser casemapping merges what now folds alike
    chat.open('test', '#a[b]')
    T.eq(#keys(), 3, 'apart under ascii')
    manager.connect 'test'
    c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 005 me CASEMAPPING=rfc1459 :are supported'
    T.eq(keys(), {'#A[B]', '#C[D]'}, 'merged')
end)

T.case('whois reports a refused remote whois', function()
    local c = boot()
    local task = T.require 'hub.runtime.task'
    local whois = T.require 'hub.features.chat.whois'
    task.spawn('whois', {net = 'test'}, whois, 'Nick', true)
    T.eq(c:take(), {'WHOIS Nick Nick'}, 'remote')
    c:recv ':srv 263 me WHOIS :Server load is temporarily too heavy.'
    T.eq(T.log_lines 'whois', {'whois Nick failed: Server load is temporarily too heavy.'}, 'refused')
    T.eq(next(HUB.tasks), nil, 'finished')
end)

T.case('whois of !nick is an operspy whois of nick', function()
    local c = boot()
    local task = T.require 'hub.runtime.task'
    local whois = T.require 'hub.features.chat.whois'
    local seen = {}
    T.require 'hub.runtime.bus'.on(HUB.current.bus, 'chat.whois', 'test', function(ev) seen[#seen + 1] = ev.whois end)
    task.spawn('whois', {net = 'test'}, whois, '!Nick')
    T.eq(c:take(), {'WHOIS !Nick'}, 'asked')
    c:recv ':srv 311 me Nick ~n h.example * :Real'
    c:recv ':srv 319 me Nick :#open !@#secret'
    c:recv ':srv 318 me !Nick :End of /WHOIS list.'
    local w = seen[1]
    T.eq({w and w.nick, w and w.operspy, w and w.channels}, {'Nick', true, {'#open', '!@#secret'}}, 'read')
    T.eq(T.log_lines 'whois', {'Nick!~n@h.example operspy, 2 channels'}, 'logged')
    T.eq(next(HUB.tasks), nil, 'finished')

    -- remotely it goes to nick's server; without oper:spy, !nick is no one
    task.spawn('whois', {net = 'test'}, whois, '!Nick', true)
    T.eq(c:take(), {'WHOIS Nick !Nick'}, 'remote')
    c:recv ':srv 401 me !Nick :No such nick/channel'
    T.eq(T.log_lines 'whois', {'Nick!~n@h.example operspy, 2 channels', 'whois failed: no such nickname'}, 'refused')
    T.eq(next(HUB.tasks), nil, 'finished too')
end)

T.case('whois reads OFTC hybrid replies', function()
    local c = boot {ircd = 'oftc-hybrid'}
    local task = T.require 'hub.runtime.task'
    local whois = T.require 'hub.features.chat.whois'
    local seen = {}
    T.require 'hub.runtime.bus'.on(HUB.current.bus, 'chat.whois', 'test', function(ev) seen[#seen + 1] = ev.whois end)
    task.spawn('whois', {net = 'test'}, whois, 'Nick')
    T.eq(c:take(), {'WHOIS Nick'}, 'asked')
    c:recv ':srv 311 me Nick ~n cloak.example * :Real'
    c:recv ':srv 307 me Nick :user has identified and verified with services'
    c:recv ':srv 320 me Nick :is really (~n@real.example)'
    c:recv ':srv 338 me Nick 192.0.2.5 :actually using host'
    c:recv ':srv 275 me Nick :is connected via SSL (secure link)'
    c:recv ':srv 318 me Nick :End of /WHOIS list.'
    local w = seen[1]
    T.eq({w.mask, w.ip, w.secure, w.specials}, {'~n@real.example', '192.0.2.5', true,
        {'user has identified and verified with services'}}, 'read')
end)

T.case('whowas gathers every past entry, and reports failures', function()
    local c = boot()
    local task = T.require 'hub.runtime.task'
    local whowas = T.require 'hub.features.chat.whowas'
    local events = {}
    T.require 'hub.runtime.bus'.on(HUB.current.bus, 'chat.whowas', 'test', function(ev) table.insert(events, ev) end)

    task.spawn('whowas', {net = 'test'}, whowas, 'Old')
    T.eq(c:take(), {'WHOWAS Old'}, 'sent')
    c:recv ':srv 314 me old u1 h1.example * :First'
    c:recv ':srv 338 me old 192.0.2.7 :actually using host'
    c:recv ':srv 330 me old acct :was logged in as'
    c:recv ':srv 312 me old srv.example :Fri Oct 30 10:00:00 2026'
    c:recv ':srv 314 me old u2 h2.example * :Second'
    c:recv ':srv 312 me old other.example :Thu Oct 29 09:00:00 2026'
    c:recv ':srv 369 me old :End of WHOWAS'
    T.eq(#events, 1, 'emitted')
    local w = events[1].whowas
    T.eq(#w.entries, 2, 'both entries')
    local first, second = w.entries[1], w.entries[2]
    T.eq({first.user, first.host, first.gecos, first.ip, first.account, first.server, first.signoff},
        {'u1', 'h1.example', 'First', '192.0.2.7', 'acct', 'srv.example', 'Fri Oct 30 10:00:00 2026'}, 'first')
    T.eq({second.user, second.server, second.account}, {'u2', 'other.example', nil}, 'second')
    T.eq(T.log_lines 'whowas', {'old!u1@h1.example Fri Oct 30 10:00:00 2026, 2 entries'}, 'one line')
    T.eq(next(HUB.tasks), nil, 'finished')

    task.spawn('whowas', {net = 'test'}, whowas, 'gone')
    c:take()
    c:recv ':srv 406 me gone :There was no such nickname'
    c:recv ':srv 369 me gone :End of WHOWAS'
    T.eq(T.log_lines 'whowas'[2], 'whowas gone: no such nickname', 'no such nick')

    task.spawn('whowas', {net = 'test'}, whowas, 'busy')
    c:take()
    c:recv ':srv 263 me WHOWAS :Server load is temporarily too heavy.'
    T.eq(T.log_lines 'whowas'[3], 'whowas busy failed: Server load is temporarily too heavy.', 'refused')
    T.eq(#events, 1, 'failures open nothing')
    T.eq(next(HUB.tasks), nil, 'finished')

    -- the command takes a count of entries
    T.command 'whowas Old 3'
    T.eq(c:take(), {'WHOWAS Old 3'}, 'with a count')
    c:recv ':srv 369 me Old :End of WHOWAS'
    T.command 'whowas Old'
    T.eq(c:take(), {'WHOWAS Old'}, 'without')
    c:recv ':srv 369 me Old :End of WHOWAS'
    T.command 'whowas Old x'
    T.eq(c:take(), {}, 'a bad count sends nothing')
    T.ok(T.log_lines 'error'[1]:find 'count must be a positive number', 'and says why')
end)

T.case("an error about a change in a channel shows in its buffer", function()
    local c, chat = boot()
    c:recv ':me!u@h JOIN #c'
    c:recv ':bob!b@h PRIVMSG me :hi'
    c:take()
    c:recv ":srv 482 me #c :You're not a channel operator"
    c:recv ":srv 441 me alice #c :They aren't on that channel"
    c:recv ':srv 478 me #c b :Channel ban list is full'
    c:recv ':srv 437 me bob :Nick/channel is temporarily unavailable'
    T.eq(texts(chat.buffer('test', '#c')), {
        'JOIN #c',
        "482 me #c You're not a channel operator",
        "441 me alice #c They aren't on that channel",
        '478 me #c b Channel ban list is full',
    }, 'the channel, found where each numeric names it')
    T.eq(#texts(chat.buffer('test', 'bob')), 1, 'a nick named where a channel can be is not one')
end)

T.case('without labeled-response, a refusal marks our newest line there', function()
    local c, chat = boot()
    c:recv ':me!u@h JOIN #m'
    chat.say('test', '#m', 'first')
    chat.say('test', '#m', 'second')
    chat.say('test', '#m', 'third')
    c:take()
    local buffer = chat.buffer('test', '#m')
    local function receipts()
        local list = {}
        for msg in T.require 'hub.lib.OrderedMap'.reveach(buffer.messages) do
            if msg.source == '>>>' then table.insert(list, msg.receipt or '-') end
        end
        return list
    end
    c:recv ':srv 404 me #m :Cannot send to nick/channel'
    T.eq(receipts(), {'-', '-', 'rejected'}, 'the newest')
    T.eq(chat.newest(buffer).rejection, 'Cannot send to nick/channel', 'with the reason')
    c:recv ':srv 404 me #m :Cannot send to nick/channel'
    T.eq(receipts(), {'-', 'rejected', 'rejected'}, 'a second error reaches the line before')
    c:recv ':srv 404 me #other :Cannot send to nick/channel'
    T.eq(receipts(), {'-', 'rejected', 'rejected'}, 'another target marks nothing here')
end)

T.case('a refused or forwarded JOIN shows in the buffer', function()
    local c, chat = boot()
    chat.talk('test', '#ban')
    c:take()
    c:recv ':srv 474 me #ban :Cannot join channel (+b) - you are banned'
    T.eq(texts(chat.buffer('test', '#ban')), {'474 me #ban Cannot join channel (+b) - you are banned'}, 'refused')
    c:recv ':srv 474 me #other :Cannot join channel (+b) - you are banned'
    T.eq(chat.buffer('test', '#other'), nil, 'no buffer opened for a refusal')

    local events = {}
    T.require 'hub.runtime.bus'.on(HUB.current.bus, 'chat.forward', 'test', function(ev) table.insert(events, ev) end)
    chat.talk('test', '#angularjs')
    c:take()
    c:recv ':srv 470 me #angularjs #angular :Forwarding to another channel'
    c:recv ':me!u@h JOIN #angular'
    local line = '470 me #angularjs #angular Forwarding to another channel'
    T.eq(texts(chat.buffer('test', '#angularjs')), {line}, 'in the buffer joined')
    T.eq(texts(chat.buffer('test', '#angular')), {line, 'JOIN #angular'}, 'and the one forwarded to')
    T.eq(#events, 1, 'one forward')
    T.eq({events[1].from, events[1].to}, {'#angularjs', '#angular'}, 'reported')
end)

T.case('channel and private messages go to buffers', function()
    local c, chat = boot({mention = {patterns = {'%f[%w]me%f[^%w]'}}})
    c:recv ':me!u@h JOIN #chan'
    T.eq(c:take(), {'CHATHISTORY LATEST #chan * 50'}, 'history for a new buffer')
    c:recv ':alice!a@h PRIVMSG #chan :hello all'
    c:recv ':alice!a@h PRIVMSG #chan :hello me'
    c:recv ':bob!b@h PRIVMSG me :psst'
    c:recv ':srv NOTICE * :*** Notice -- not chat'

    local chan = chat.buffer('test', '#CHAN')
    T.eq(texts(chan), {'JOIN #chan', 'PRIVMSG #chan hello all', 'PRIVMSG #chan hello me'}, 'channel')
    T.eq({chan.activity, chan.mention}, {2, true}, 'activity and mention')
    local query = chat.buffer('test', 'Bob')
    T.eq(texts(query), {'PRIVMSG me psst'}, 'private message in a buffer named for the sender')
    T.eq(query.mention, true, 'private messages mention')
    T.eq(chat.buffer('test', '*'), nil, 'server notices are not chat')

    chat.look(chan)
    T.eq({chan.activity, chan.mention}, {0, false}, 'seen')
end)

T.case('global mention patterns apply without network ones', function()
    local c, chat = boot(nil, {mention = {patterns = {'snowcone'}}})
    c:recv ':alice!a@h PRIVMSG #c :I like snowcone'
    T.eq(chat.buffer('test', '#c').mention, true, 'global pattern')
end)

T.case('statusmsg, echo and membership changes', function()
    local c, chat = boot()
    c:recv ':me!u@h JOIN #c'
    c:recv ':alice!a@h JOIN #c'
    c:recv ':alice!a@h PRIVMSG @#c :ops only'
    local msg = chat.newest(chat.buffer('test', '#c'))
    T.eq(msg.statusmsg, '@', 'statusmsg prefix')

    chat.say('test', '#c', 'from me')
    T.eq(texts(chat.buffer('test', '#c'))[4], 'PRIVMSG #c from me', 'echoed')
    T.eq(chat.buffer('test', '#c').activity, 1, 'our own messages are not activity')

    c:recv ':alice!a@h PRIVMSG me :hi'
    c:recv ':alice!a@h NICK alicia'
    T.eq(chat.buffer('test', 'alice'), nil, 'renamed buffer gone from the old name')
    local renamed = chat.buffer('test', 'alicia')
    T.eq(renamed.name, 'alicia', 'buffer follows the nick')
    T.eq(texts(chat.buffer('test', '#c'))[5], 'NICK alicia', 'nick change in the channel')

    c:recv ':alicia!a@h QUIT :bye'
    T.eq(texts(chat.buffer('test', '#c'))[6], 'QUIT bye', 'quit in the channel the user was in')
    T.eq(texts(renamed)[3], 'QUIT bye', 'and in the private buffer')
end)

T.case('channel lines keep the modes their sender had then', function()
    local c, chat = boot()
    c:recv ':me!u@h JOIN #c'
    c:recv ':srv 353 me = #c :@me +alice bob'
    c:recv ':srv 366 me #c :End of /NAMES list.'
    c:recv ':alice!a@h PRIVMSG #c :voiced'
    local before = chat.newest(chat.buffer('test', '#c'))
    c:recv ':srv MODE #c -v+o alice alice'
    c:recv ':alice!a@h PRIVMSG #c :opped'
    local after = chat.newest(chat.buffer('test', '#c'))
    T.eq({before.member_modes, after.member_modes}, {{v = true}, {o = true}}, 'as of each line')
    c:recv ':bob!b@h PRIVMSG #c :plain'
    T.eq(chat.newest(chat.buffer('test', '#c')).member_modes, {}, 'a member without modes')
    c:recv ':eve!e@h PRIVMSG #c :from outside'
    T.eq(chat.newest(chat.buffer('test', '#c')).member_modes, nil, 'not a member')
    c:recv ':alice!a@h PRIVMSG me :private'
    T.eq(chat.newest(chat.buffer('test', 'alice')).member_modes, nil, 'not in a channel')
    chat.say('test', '#c', 'mine')
    T.eq(chat.newest(chat.buffer('test', '#c')).member_modes, {o = true}, 'ours when sent')
end)

T.case('what a user sends a channel keeps their modes from before it took effect', function()
    local c, chat = boot()
    c:recv ':me!u@h JOIN #c'
    c:recv ':srv 353 me = #c :me @alice +bob carol'
    c:recv ':srv 366 me #c :End of /NAMES list.'
    local function newest() return chat.newest(chat.buffer('test', '#c')) end
    c:recv ':alice!a@h TOPIC #c :hi'
    T.eq(newest().member_modes, {o = true}, 'TOPIC')
    c:recv ':alice!a@h MODE #c -o alice'
    T.eq(newest().member_modes, {o = true}, 'MODE, as before the change')
    c:recv ':bob!b@h KICK #c carol :bye'
    T.eq(newest().member_modes, {v = true}, 'KICK')
    c:recv ':bob!b@h PART #c :gone'
    T.eq(newest().member_modes, {v = true}, 'PART, as before leaving')
    c:recv ':alice!a@h NOTICE +#c :voiced only'
    T.eq(newest().member_modes, {}, 'behind a STATUSMSG prefix')
    c:recv ':dave!d@h JOIN #c'
    T.eq(newest().member_modes, nil, 'not JOIN')
end)

T.case('typing is tracked in buffers until it lapses or ends', function()
    local c, chat = boot()
    local clock = T.require 'hub.runtime.clock'
    local now = clock.now()
    clock.now = function() return now end
    local function typing(target)
        local list = {}
        for _, entry in ipairs(chat.typing('test', chat.buffer('test', target))) do
            table.insert(list, entry.nick .. ' ' .. entry.state)
        end
        return list
    end

    c:recv ':me!u@h JOIN #c'
    c:recv ':alice!a@h JOIN #c'
    c:recv '@+typing=active :bob!b@h TAGMSG me'
    T.eq(chat.buffer('test', 'bob'), nil, 'typing to us opens no buffer')
    c:recv ':bob!b@h PRIVMSG me :hi'
    c:recv '@+typing=active :bob!b@h TAGMSG me'
    T.eq(typing 'bob', {'bob active'}, 'in the private buffer')

    c:recv '@+typing=active :alice!a@h TAGMSG #c'
    c:recv '@+typing=paused :Bob!b@h TAGMSG @#c'
    c:recv '@+typing=active :me!u@h TAGMSG #c'
    T.eq(typing '#c', {'alice active', 'Bob paused'}, 'sorted, statusmsg included, ours ignored')

    now = now + 6
    T.eq(typing '#c', {'Bob paused'}, 'active lapses after 6 seconds')
    c:recv '@+typing=active :alice!a@h TAGMSG #c'
    c:recv '@+typing=done :bob!b@h TAGMSG #c'
    T.eq(typing '#c', {'alice active'}, 'done ends it')

    now = now + 1
    c:recv '@+typing=paused :Bob!b@h TAGMSG #c'
    T.eq(typing '#c', {'Bob paused', 'alice active'}, 'the latest change first')
    now = now + 1
    c:recv '@+typing=active :alice!a@h TAGMSG #c'
    c:recv '@+typing=paused :Bob!b@h TAGMSG #c'
    T.eq(typing '#c', {'Bob paused', 'alice active'}, 'refreshing is no change')
    c:recv '@+typing=done :bob!b@h TAGMSG #c'

    c:recv ':alice!a@h PRIVMSG #c :sent'
    T.eq(typing '#c', {}, 'a message ends it')

    c:recv '@+typing=active :alice!a@h TAGMSG #c'
    c:recv '@+typing=active :bob!b@h TAGMSG me'
    c:recv ':alice!a@h NICK alicia'
    T.eq(typing '#c', {'alicia active'}, 'follows a nick change')
    c:recv ':bob!b@h NICK robert'
    T.eq(typing 'robert', {'robert active'}, 'and the renamed private buffer')
    c:recv ':dave!d@h PRIVMSG me :one'
    c:recv ':dan!d@h PRIVMSG me :two'
    c:recv '@+typing=active :dave!d@h TAGMSG me'
    c:recv ':dave!d@h NICK dan'
    T.eq({typing 'dave', typing 'dan'}, {{}, {}}, 'not carried into a buffer kept apart')
    c:recv ':alicia!a@h PART #c'
    T.eq(typing '#c', {}, 'parting ends it')

    c:recv '@+typing=active :carol!c@h TAGMSG #c'
    c:recv ':op!o@h KICK #c me :out'
    T.eq(typing '#c', {}, 'leaving ourselves ends everyone\'s')
    c:recv ':robert!b@h QUIT :bye'
    T.eq(typing 'robert', {}, 'quitting ends it')

    c:recv '@+typing=active :robert!b@h TAGMSG me'
    c:finish 'reset'
    T.eq(typing 'robert', {}, 'disconnecting ends it')
end)

-- Boot as boot does, with message-tags and more ISUPPORT tokens
local function boot_tags(isupport, extra)
    local fake = FakeTransport.new()
    local net = {id = 'test', server = {host = 'test.example', port = 6667}, identity = {nick = 'me'}}
    for k, v in pairs(extra or {}) do net[k] = v end
    T.boot {transport = fake, config = {networks = {net}}}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :message-tags'
    c:recv ':srv CAP me ACK :message-tags'
    c:recv ':srv 001 me :Welcome'
    c:recv(':srv 005 me CHANTYPES=# MONITOR=100 ' .. (isupport or 'STATUSMSG=@+') .. ' :are supported')
    c:recv ':srv 376 me :End of MOTD'
    c:recv ':me!u@h JOIN #c'
    c:recv ':me!u@h JOIN #d'
    c:take()
    return c, T.require 'hub.features.chat'
end

T.case('client-only tags follow message-tags and CLIENTTAGDENY', function()
    boot()
    local irc_model = T.require 'hub.net.irc'
    local function allowed(deny, caps)
        local irc = {caps_enabled = caps or {['message-tags'] = true}, isupport = {CLIENTTAGDENY = deny}}
        return irc_model.client_tag_allowed(irc, 'typing')
    end
    T.eq(allowed(nil, {}), false, 'not without message-tags')
    T.eq(allowed(nil), true, 'everything without a deny list')
    T.eq({allowed 'typing', allowed 'react,typing', allowed 'react'}, {false, false, true}, 'by name')
    T.eq({allowed '*', allowed '*,-typing', allowed '*,-react'}, {false, true, false}, 'all but exceptions')
end)

T.case('our typing goes out active, refreshed, paused and done', function()
    local c, chat = boot_tags()
    local clock = T.require 'hub.runtime.clock'
    local now = clock.now()
    clock.now = function() return now end

    chat.compose('test', '#c', 'h')
    T.eq(c:take(), {'@+typing=active TAGMSG #c'}, 'active at once')
    chat.compose('test', '#c', 'hi')
    now = now + 3
    chat.compose('test', '#c', 'hi')
    T.eq(c:take(), {}, 'not again within 4 seconds')
    now = now + 1
    chat.compose('test', '#c', 'hi')
    T.eq(c:take(), {'@+typing=active TAGMSG #c'}, 'refreshed while the last change is recent')
    now = now + 6
    chat.compose('test', '#c', 'hi')
    chat.compose('test', '#c', 'hi')
    T.eq(c:take(), {'@+typing=paused TAGMSG #c'}, 'paused once, 10 seconds after the last change')
    chat.compose('test', '#c', 'hi!')
    T.eq(c:take(), {'@+typing=active TAGMSG #c'}, 'active again on a change')

    chat.compose('test', '#D', 'x')
    T.eq(c:take(), {'@+typing=done TAGMSG #c', '@+typing=active TAGMSG #D'}, 'moving ends it')
    chat.compose('test', '#d', '')
    chat.compose('test', '#d', '')
    T.eq(c:take(), {'@+typing=done TAGMSG #D'}, 'emptying ends it, once')
    chat.compose('test', '#d', 'x')
    chat.compose(nil, nil, '')
    T.eq(c:take(), {'@+typing=active TAGMSG #d', '@+typing=done TAGMSG #d'}, 'so does stopping')

    chat.compose('test', '#d', 'hello')
    chat.say('test', '#d', 'hello')
    chat.compose(nil, nil, '')
    T.eq(c:take(), {'@+typing=active TAGMSG #d', 'PRIVMSG #d hello'}, 'our message ends it without done')

    chat.compose('test', '#c', 'x')
    c:finish 'reset'
    T.eq(chat.get('test').composing, nil, 'disconnecting forgets it')
end)

T.case('our typing goes only where it can, and only at once', function()
    local c, chat = boot_tags()
    local clock = T.require 'hub.runtime.clock'
    local now = clock.now()
    clock.now = function() return now end
    c:recv ':irc.example WALLOPS :hello'
    for _, target in ipairs {'#elsewhere', 'nobody', 'irc.example'} do
        chat.compose('test', target, 'x')
        chat.compose(nil, nil, '')
    end
    T.eq(c:take(), {}, 'not to a channel we are not in, a missing buffer or a server')

    c:recv ':bob!b@h PRIVMSG me :hi'
    T.eq(c:take(), {'MONITOR + bob'}, 'a private buffer watches its nick')
    c:recv ':srv 731 me :bob'
    chat.compose('test', 'bob', 'x')
    T.eq(c:take(), {}, 'not to a nick known to be offline')
    c:recv ':srv 730 me :bob!b@h'
    chat.compose('test', 'bob', 'xy')
    T.eq(c:take(), {'@+typing=active TAGMSG bob'}, 'once it is online')

    c:recv ':srv 404 me #C :Cannot send to channel'
    chat.compose('test', 'bob', 'xyz')
    T.eq(c:take(), {}, 'an error about another buffer is no matter')
    chat.compose('test', '#c', 'x')
    c:take()
    c:recv ':srv 404 me #C :Cannot send to channel'
    now = now + 4
    chat.compose('test', '#c', 'xy')
    chat.compose(nil, nil, '')
    T.eq(c:take(), {}, 'refused: no more there, nor done')
    chat.compose('test', '#c', 'x')
    T.eq(c:take(), {'@+typing=active TAGMSG #c'}, 'the next line tries again')
    c:recv 'FAIL TAGMSG INVALID_TARGET #c :no'
    now = now + 4
    chat.compose('test', '#c', 'xy')
    T.eq(c:take(), {}, 'FAIL TAGMSG refuses too')
    chat.compose(nil, nil, '')

    HUB.state.nets.test.cfg.rate_limit = {burst = 1, interval = 60}
    T.require 'hub.net.send'.send('test', 'PRIVMSG', '#c', 'fill the burst')
    c:take()
    chat.compose('test', '#c', 'x')
    T.eq(c:take(), {}, 'not held back by the rate limit')
    T.eq(HUB.state.nets.test.sendq.lines, {}, 'nor queued')

    for _, deny in ipairs {'typing', '*'} do
        c, chat = boot_tags('CLIENTTAGDENY=' .. deny)
        chat.compose('test', '#c', 'x')
        T.eq(c:take(), {}, 'not when CLIENTTAGDENY=' .. deny)
    end
    c, chat = boot_tags 'CLIENTTAGDENY=*,-typing'
    chat.compose('test', '#c', 'x')
    T.eq(c:take(), {'@+typing=active TAGMSG #c'}, 'but when excepted')
end)

T.case('every buffer a queued line went to shows its delivery', function()
    local c, chat = boot {rate_limit = {burst = 1, interval = 60}}
    c:recv ':me!u@h JOIN #a'
    c:recv ':me!u@h JOIN #b'
    T.require 'hub.net.send'.send('test', 'PRIVMSG', '#a', 'fill the burst')
    chat.say('test', '#a,@#b', 'both')
    local a = chat.newest(chat.buffer('test', '#a'))
    local b = chat.newest(chat.buffer('test', '#b'))
    T.eq({a[2], b[2], b.statusmsg}, {'both', 'both', '@'}, 'in both buffers')
    T.eq({a[1], b[1]}, {'#a', '@#b'}, 'each naming its own target')
    T.eq(a.delivery, {state = 'queued'}, 'queued')
    T.ok(a.delivery == b.delivery, 'the statusmsg copy shares the delivery')
    c:finish 'reset'
    T.eq(b.delivery.state, 'dropped', 'both dropped together')
end)

T.case('history goes before the message that opened the buffer', function()
    local c, chat = boot()
    c:recv '@time=2026-01-01T00:00:10.000Z :bob!b@h PRIVMSG me :newest'
    T.eq(c:take(), {'CHATHISTORY BEFORE bob timestamp=2026-01-01T00:00:10.000Z 50', 'MONITOR + bob'},
        'asked for what came before, and watching bob')
    c:recv ':srv BATCH +h1 chathistory bob'
    c:recv '@batch=h1;time=2026-01-01T00:00:01.000Z :bob!b@h PRIVMSG me :older'
    c:recv '@batch=h1;time=2026-01-01T00:00:05.000Z :me!u@h PRIVMSG bob :reply'
    c:recv ':srv BATCH -h1'
    T.eq(texts(chat.buffer('test', 'bob')), {'PRIVMSG me older', 'PRIVMSG bob reply', 'PRIVMSG me newest'}, 'in order')

    -- overlapping history (after a reconnect) adds nothing twice
    c:recv ':srv BATCH +h2 chathistory bob'
    c:recv '@batch=h2;time=2026-01-01T00:00:05.000Z :me!u@h PRIVMSG bob :reply'
    c:recv '@batch=h2;time=2026-01-01T00:00:10.000Z :bob!b@h PRIVMSG me :newest'
    c:recv ':srv BATCH -h2'
    T.eq(#texts(chat.buffer('test', 'bob')), 3, 'no duplicates')
end)

T.case('messages are found by msgid, and one already held is not added again', function()
    local c, chat = boot()
    c:recv '@msgid=m1 :bob!b@h PRIVMSG me :live'
    c:recv ':srv BATCH +h1 chathistory bob'
    c:recv '@batch=h1;msgid=m0 :bob!b@h PRIVMSG me :history'
    c:recv ':srv BATCH -h1'
    local buffer = chat.buffer('test', 'bob')
    T.eq({chat.find(buffer, 'm0')[2], chat.find(buffer, 'm1')[2]}, {'history', 'live'}, 'both found')
    T.eq(chat.find(buffer, 'M1'), nil, 'msgids are not folded')

    c:recv '@msgid=m1 :bob!b@h PRIVMSG me :live'
    T.eq(texts(buffer), {'PRIVMSG me history', 'PRIVMSG me live'}, 'not repeated')
    T.eq(buffer.activity, 1, 'and not counted')
end)

-- Register with labels and echoes
local function boot_echo()
    local fake = FakeTransport.new()
    T.boot {transport = fake, config = {networks = {
        {id = 'test', server = {host = 'h', port = 1}, identity = {nick = 'me'}}}}}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :batch echo-message labeled-response message-tags'
    c:recv ':srv CAP me ACK :batch echo-message labeled-response message-tags'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 005 me CHANTYPES=# STATUSMSG=@+ :are supported'
    c:recv ':srv 376 me :End of MOTD'
    c:recv ':me!u@h JOIN #a'
    c:recv ':me!u@h JOIN #b'
    c:take()
    return c, T.require 'hub.features.chat'
end

T.case('a private message with channel-context shows in the channel', function()
    local c, chat = boot_echo()
    local a = chat.buffer('test', '#a')
    c:recv '@+draft/channel-context=#a :alice!a@h PRIVMSG me :psst'
    local msg = chat.newest(a)
    T.eq({msg[2], msg.context, msg.statusmsg}, {'psst', '>', nil}, 'in #a, marked')
    T.eq(chat.buffer('test', 'alice'), nil, 'no private buffer')
    T.eq({a.mention, a.activity}, {true, 1}, 'a mention, as a private message is')

    c:recv '@+channel-context=#a :alice!a@h PRIVMSG me :undrafted'
    T.eq(chat.newest(a).context, '>', 'the name without draft/ too')
    c:recv '@+draft/channel-context=#elsewhere :alice!a@h PRIVMSG me :away'
    T.eq(texts(chat.buffer('test', 'alice')), {'PRIVMSG me away'}, 'a channel we are not in: privately')
    c:recv '@+draft/channel-context=#a :alice!a@h PRIVMSG #b :odd'
    local odd = chat.newest(chat.buffer('test', '#b'))
    T.eq({odd[2], odd.context}, {'odd', nil}, 'to a channel: in that channel')

    -- ours, from /cmsg in the shown channel
    T.command('cmsg bob hello', 'test', '#a')
    T.eq(c:take(), {'@+channel-context=#a;label=sc1 PRIVMSG bob hello'}, 'tagged')
    local mine = chat.newest(a)
    T.eq({mine[1], mine[2], mine.context, mine.receipt}, {'bob', 'hello', '<', 'awaiting'}, 'in #a, marked')
    T.eq(chat.buffer('test', 'bob'), nil, 'no private buffer')
    c:recv '@label=sc1;msgid=m1;+channel-context=#a :me!u@h PRIVMSG bob :hello'
    T.eq({mine.receipt, mine.tags.msgid}, {'received', 'm1'}, 'its echo confirms it')
    T.ok(chat.find(a, 'm1') == mine, 'found by its msgid')

    -- ours from another client, relayed
    c:recv '@msgid=m2;+draft/channel-context=#a :me!u@h PRIVMSG bob :relayed'
    T.eq({chat.newest(a)[2], chat.newest(a).context}, {'relayed', '<'}, 'in #a, marked')

    T.command('cmsg bob hi', 'test', 'bob')
    T.command('cmsg #b hi', 'test', '#a')
    T.eq(c:take(), {}, 'only from a channel, only to a nick')
    local errors = T.log_lines 'error'
    T.ok(errors[#errors - 1]:find 'not a channel', 'not from a private buffer')
    T.ok(errors[#errors]:find 'not a nick', 'not to a channel')
end)

T.case('/cmsg needs client tags, and the channel-context tag', function()
    local c = boot()
    c:recv ':me!u@h JOIN #c'
    c:take()
    T.command('cmsg bob hi', 'test', '#c')
    T.eq(c:take(), {}, 'nothing sent')
    local errors = T.log_lines 'error'
    T.ok(errors[#errors]:find('has not enabled message-tags', 1, true), 'and says why')

    -- as Solanum announces it
    c = boot_tags 'CLIENTTAGDENY=*,-draft/react,-draft/reply,-channel-context'
    T.command('cmsg bob hi', 'test', '#c')
    T.eq(c:take(), {'@+channel-context=#c PRIVMSG bob hi'}, 'sent where excepted')
    c = boot_tags 'CLIENTTAGDENY=*'
    T.command('cmsg bob hi', 'test', '#c')
    T.eq(c:take(), {}, 'not where denied')
    errors = T.log_lines 'error'
    T.ok(errors[#errors]:find('refuses the channel-context tag (CLIENTTAGDENY=*)', 1, true), 'and says why')
end)

T.case('an echo confirms our message and gives it its msgid', function()
    local c, chat = boot_echo()
    local a = chat.buffer('test', '#a')
    chat.say('test', '#a', 'hello')
    T.eq(c:take(), {'@label=sc1 PRIVMSG #a hello'}, 'labeled')
    local mine = chat.newest(a)
    T.eq(mine.receipt, 'awaiting', 'awaiting')

    c:recv '@label=sc1;msgid=m1;time=2026-01-01T00:00:00.000Z :me!u@h PRIVMSG #a :hello'
    T.eq(texts(a), {'JOIN #a', 'PRIVMSG #a hello'}, 'the echo is not shown again')
    T.eq({mine.receipt, mine.tags.msgid, mine.tags.time}, {'received', 'm1', '2026-01-01T00:00:00.000Z'}, 'received')
    T.ok(chat.find(a, 'm1') == mine, 'found by its msgid')
    T.eq(chat.get('test').pending, {}, 'settled')

    -- history with the same message adds nothing
    c:recv ':srv BATCH +h chathistory #a'
    c:recv '@batch=h;msgid=m1;time=2026-01-01T00:00:00.000Z :me!u@h PRIVMSG #a :hello'
    c:recv ':srv BATCH -h'
    T.eq(#texts(a), 2, 'no duplicate from history')
end)

T.case('the buffer shows the echo as the server edited it; the console what was sent', function()
    local c, chat = boot_echo()
    local sent = {}
    T.require 'hub.runtime.bus'.on(HUB.current.bus, 'irc.sent', 'test', function(ev)
        table.insert(sent, ev.msg)
    end)
    chat.say('test', '#a', '\x0304red\x03 text')
    c:recv '@label=sc1;msgid=m1;account=me :me!u@h PRIVMSG #a :red text'
    local mine = chat.newest(chat.buffer('test', '#a'))
    T.eq({mine[2], mine.tags.account, mine.source}, {'red text', 'me', '>>>'}, 'the echo, still drawn as ours')
    T.eq(sent[1][2], '\x0304red\x03 text', 'the sent line is unchanged')
    T.ok(sent[1] ~= mine, 'a copy')
end)

T.case('ACK confirms, an error refuses, and a lost connection leaves it unknown', function()
    local c, chat = boot_echo()
    local a = chat.buffer('test', '#a')
    chat.say('test', '#a', 'one')
    c:recv '@label=sc1 :srv ACK'
    T.eq(chat.newest(a).receipt, 'received', 'ACK')

    T.require 'hub.net.send'.send('test', 'NOTICE', '#a', 'two')
    c:recv '@label=sc2 :srv 404 me #a :Cannot send to nick/channel'
    local refused = chat.newest(a)
    T.eq({refused.receipt, refused.rejection}, {'rejected', 'Cannot send to nick/channel'}, 'refused')

    chat.say('test', 'nobody', 'unseen')
    c:recv '@label=sc3;msgid=m3 :me!u@h PRIVMSG nobody :unseen'
    T.eq(chat.buffer('test', 'nobody'), nil, 'an echo opens no buffer')

    chat.say('test', '#a', 'three')
    c:finish 'reset'
    T.eq(chat.newest(a).receipt, 'unknown', 'never answered')
    T.eq(chat.get('test').pending, {}, 'forgotten with the connection')
end)

T.case('an away reply in a labeled reply only informs', function()
    local c, chat = boot_echo()
    chat.open('test', 'bob')
    chat.say('test', 'bob', 'hi')
    c:recv '@label=sc1 :srv BATCH +r labeled-response'
    c:recv '@batch=r :srv 301 me bob :gone fishing'
    c:recv '@batch=r;msgid=m1 :me!u@h PRIVMSG bob :hi'
    c:recv ':srv BATCH -r'
    local mine = chat.newest(chat.buffer('test', 'bob'))
    T.eq({mine.receipt, mine.tags.msgid}, {'received', 'm1'}, 'received, with its msgid')
end)

T.case('each target of a line gets its own echo', function()
    local c, chat = boot_echo()
    chat.say('test', '#a,@#b', 'both')
    c:recv '@label=sc1 :srv BATCH +r labeled-response'
    c:recv '@batch=r;msgid=ma :me!u@h PRIVMSG #a :both'
    c:recv '@batch=r;msgid=mb :me!u@h PRIVMSG @#b :both'
    local a, b = chat.newest(chat.buffer('test', '#a')), chat.newest(chat.buffer('test', '#b'))
    T.eq({a.receipt, b.receipt}, {'received', 'received'}, 'both received')
    c:recv ':srv BATCH -r'
    T.eq({a.tags.msgid, b.tags.msgid, b.statusmsg}, {'ma', 'mb', '@'}, 'each its own msgid')
    T.eq(#texts(chat.buffer('test', '#b')), 2, 'no echo shown')
    T.eq(chat.get('test').pending, {}, 'settled by the end of the batch')
end)

T.case('an error naming one target refuses only that one; the rest stay unknown', function()
    local c, chat = boot_echo()
    chat.say('test', '#a,#b', 'both')
    c:recv '@label=sc1 :srv BATCH +r labeled-response'
    c:recv '@batch=r :srv 404 me #b :Cannot send to nick/channel'
    c:recv ':srv BATCH -r'
    local a, b = chat.newest(chat.buffer('test', '#a')), chat.newest(chat.buffer('test', '#b'))
    T.eq({a.receipt, b.receipt, b.rejection}, {'unknown', 'rejected', 'Cannot send to nick/channel'}, 'only #b refused')
    T.eq(chat.get('test').pending, {}, 'settled')
end)

T.case('an error naming no target refuses them all', function()
    local c, chat = boot_echo()
    chat.say('test', '#a,#b', 'both')
    c:recv '@label=sc1 :srv 417 me :Input line was too long'
    local a, b = chat.newest(chat.buffer('test', '#a')), chat.newest(chat.buffer('test', '#b'))
    T.eq({a.receipt, b.receipt}, {'rejected', 'rejected'}, 'both refused')
    T.eq(a.rejection, 'Input line was too long', 'with its text')
    T.eq(chat.get('test').pending, {}, 'settled')
end)

T.case('a nick change onto an existing buffer renames nothing', function()
    local c, chat = boot()
    c:recv ':alice!a@h PRIVMSG me :from alice'
    c:recv ':alice_!a@h PRIVMSG me :from alice_'
    c:recv ':alice_!a@h NICK alice'
    T.eq(texts(chat.buffer('test', 'alice')), {'PRIVMSG me from alice'}, 'alice kept')
    T.eq(texts(chat.buffer('test', 'alice_')), {'PRIVMSG me from alice_', 'NICK alice'}, 'alice_ kept, with the change')
end)

T.case('wallops and broadcasts go to the sender\'s buffer', function()
    local c, chat = boot()
    c:recv ':oper!o@h WALLOPS :maintenance soon'
    c:recv ':oper!o@h OPERWALL :opers only'
    T.eq(#texts(chat.buffer('test', 'oper')), 2, 'both from oper')
    c:recv ':irc.example WALLOPS :from a server'
    c:recv ':NickServ!s@services.example NOTICE $$*.example :services restart'
    c:recv ':alice!a@h PRIVMSG $$*.example :hello all'
    T.eq(#texts(chat.buffer('test', 'irc.example')), 1, 'a server its own')
    T.eq(#texts(chat.buffer('test', 'NickServ')), 1, 'a global notice from NickServ')
    local alice = chat.buffer('test', 'alice')
    T.eq({#texts(alice), alice.mention, alice.activity}, {1, false, 1}, 'unseen, not a mention')
    local sent = c:take()
    T.ok(not table.concat(sent, '\n'):find 'irc.example', 'a server is not monitored: ' .. table.concat(sent, ' '))
end)

T.case('our own messages are never mentions or unseen', function()
    local c, chat = boot({}, {mention = {patterns = {'me'}}})
    c:recv ':me!u@h JOIN #c'
    c:recv ':me!u@h PRIVMSG #c :me too, from another client'
    c:recv ':me!u@h PRIVMSG bob :and to bob'
    local channel = chat.buffer('test', '#c')
    T.eq({channel.mention, channel.activity}, {false, 0}, 'the channel')
    local bob = chat.buffer('test', 'bob')
    T.eq({bob.mention, bob.activity}, {false, 0}, 'the private buffer')
    local sent = c:take()
    T.eq(sent[#sent], 'MONITOR + bob', 'still watched')
end)

T.case('a flood of new senders makes a few history requests, and CTCP requests are not mentions', function()
    local c, chat = boot()
    for i = 1, 30 do c:recv(':spam' .. i .. '!s@h PRIVMSG me :hi') end
    local requests = 0
    for _, line in ipairs(c:take()) do
        if line:match '^CHATHISTORY' then requests = requests + 1 end
    end
    T.eq(requests, chat.history_burst, 'a burst of requests')
    c:recv ':bob!b@h PRIVMSG me :\x01VERSION\x01'
    T.eq(chat.buffer('test', 'bob').mention, false, 'VERSION is not a mention')
    c:recv ':carol!c@h PRIVMSG me :\x01ACTION waves\x01'
    T.eq(chat.buffer('test', 'carol').mention, true, 'an action is')
end)

T.case('/list counts the channels it could not keep', function()
    local c, chat = boot()
    T.command 'list'
    local C = chat.get('test')
    C.list = T.require 'hub.lib.OrderedMap'.new(3)
    for i = 1, 5 do c:recv(':srv 322 me #c' .. i .. ' 1 :topic') end
    c:recv ':srv 323 me :End of /LIST'
    T.eq({T.require 'hub.lib.OrderedMap'.size(C.list), C.list_count}, {3, 5}, 'kept 3 of 5')
end)

T.case('/msg opens the target\'s buffer', function()
    local c, chat = boot()
    T.command('msg carol hello')
    T.ok(chat.buffer('test', 'carol'), 'opened')
    T.eq(texts(chat.buffer('test', 'carol')), {'PRIVMSG carol hello'}, 'with the line')
    c:take()
end)

T.case('a private buffer\'s MONITOR follows its nick, and spares the nick being reclaimed', function()
    local c, chat = boot()
    T.command 'talk Carol'
    T.eq(c:take(), {'CHATHISTORY LATEST Carol * 50', 'MONITOR + Carol'}, 'watched')
    c:recv ':srv 730 me :Carol!c@h'
    c:recv ':Carol!c@h NICK Caroline'
    T.eq(c:take(), {'MONITOR - Carol', 'MONITOR + Caroline'}, 'renamed')

    HUB.state.nets.test.irc.recover_nick = 'wanted'
    T.command 'talk wanted'
    c:recv ':srv 731 me :wanted'
    c:take()
    T.command 'close wanted'
    T.eq(c:take(), {}, 'the reclaim keeps its MONITOR')
end)

T.case('history absorbs our unconfirmed lines instead of repeating them', function()
    local c, chat = boot()
    c:recv ':me!u@h JOIN #c'
    c:recv '@time=2026-01-01T00:00:01.000Z;msgid=a1 :alice!a@h PRIVMSG #c :before'
    chat.say('test', '#c', 'hi')
    chat.say('test', '#c', 'hi')
    c:take()
    local history = T.require 'hub.features.chat.history'
    history.after_registration(chat, 'test')
    T.eq(c:take(), {'CHATHISTORY LATEST #c timestamp=2026-01-01T00:00:01.000Z 50'},
        'LATEST from the newest server time, not from our lines')

    c:recv ':srv BATCH +h1 chathistory #c'
    c:recv '@batch=h1;time=2026-01-01T00:00:02.000Z;msgid=m1 :me!u@h PRIVMSG #c :hi'
    c:recv '@batch=h1;time=2026-01-01T00:00:03.000Z;msgid=m2 :me!u@h PRIVMSG #c :hi'
    c:recv '@batch=h1;time=2026-01-01T00:00:04.000Z;msgid=m3 :me!u@h PRIVMSG #c :hi'
    c:recv ':srv BATCH -h1'
    local lines = {}
    for msg in T.require 'hub.lib.OrderedMap'.reveach(chat.buffer('test', '#c').messages) do
        if msg.command == 'PRIVMSG' then table.insert(lines, (msg.tags.msgid or '-') .. ' ' .. msg[2]) end
    end
    T.eq(lines, {'m3 hi', 'a1 before', 'm1 hi', 'm2 hi'}, 'each of ours once, the third from history')
end)

T.case('chat history fills its buffer', function()
    local c, chat = boot()
    c:recv ':me!u@h JOIN #c'
    c:take()
    c:recv ':srv BATCH +h1 chathistory #c'
    c:recv '@batch=h1;time=2026-01-01T00:00:00.000Z :alice!a@h PRIVMSG #c :old one'
    c:recv '@batch=h1;time=2026-01-01T00:00:01.000Z :alice!a@h PRIVMSG +#c :old two'
    c:recv ':srv BATCH -h1'
    local list = texts(chat.buffer('test', '#c'))
    T.eq({list[1], list[3]}, {'PRIVMSG #c old one', 'JOIN #c'}, 'history before the newer JOIN')
    T.eq(chat.buffer('test', '#c').activity, 0, 'history is not activity')
end)

T.case('history after a reconnect goes between old and new messages', function()
    local c, chat = boot()
    c:recv ':me!u@h JOIN #c'
    c:recv '@time=2026-01-01T00:00:09.000Z :alice!a@h PRIVMSG #c :before'
    -- as if registered again: what arrives from now on is the new connection
    HUB.state.nets.test.registered_at = T.require 'hub.runtime.clock'.now()
    c:recv ':alice!a@h PRIVMSG #c :after'
    -- server times that would sort first are not compared
    c:recv ':srv BATCH +h1 chathistory #c'
    c:recv '@batch=h1;time=2000-01-01T00:00:00.000Z :alice!a@h PRIVMSG #c :missed'
    c:recv '@batch=h1;time=2026-01-01T00:00:09.000Z :alice!a@h PRIVMSG #c :before'
    c:recv ':srv BATCH -h1'
    T.eq(texts(chat.buffer('test', '#c')),
        {'JOIN #c', 'PRIVMSG #c before', 'PRIVMSG #c missed', 'PRIVMSG #c after'}, 'in place')
    for msg in T.require 'hub.lib.OrderedMap'.reveach(chat.buffer('test', '#c').messages) do
        T.eq(msg.timestamp == nil, msg[2] == 'missed', 'only history is drawn as old: ' .. tostring(msg[2]))
        T.eq(msg.history, msg[2] == 'missed' or nil, 'and marked as history: ' .. tostring(msg[2]))
    end
end)

T.case('history and MONITOR after registration', function()
    local fake = FakeTransport.new()
    T.boot {transport = fake, config = {networks = {
        {id = 'test', server = {host = 'h', port = 1}, identity = {nick = 'me'}}}}}
    local chat = T.require 'hub.features.chat'
    chat.open('test', '#c')
    chat.open('test', 'Bob')
    chat.open('test', '#t')
    chat.insert(chat.buffer('test', '#t'),
        {command = 'PRIVMSG', tags = {time = '2026-01-01T00:00:09.000Z'}, '#t', 'last seen'})
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :draft/chathistory'
    c:recv ':srv CAP me ACK :draft/chathistory'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 005 me MONITOR=100 :are supported'
    c:recv ':srv 376 me :End of MOTD'
    local sent = c:take()
    local tablex = T.require 'pl.tablex'
    T.ok(tablex.find(sent, 'CHATHISTORY LATEST #c * 1000'), 'channel history')
    T.ok(tablex.find(sent, 'CHATHISTORY LATEST Bob * 1000'), 'private history')
    T.ok(tablex.find(sent, 'CHATHISTORY LATEST #t timestamp=2026-01-01T00:00:09.000Z 1000'), 'since the newest message')
    T.ok(tablex.find(sent, 'MONITOR + Bob'), 'monitor')
end)

T.case('CTCP replies only to staff', function()
    local c = boot()
    local function notices()
        local list = {}
        for _, line in ipairs(c:take()) do
            if line:match '^NOTICE' then table.insert(list, line) end
        end
        return list
    end
    c:recv ':nobody!n@h PRIVMSG me :\x01VERSION\x01'
    T.eq(notices(), {}, 'ignored')
    c:recv '@solanum.chat/oper :staff!s@h PRIVMSG me :\x01PING 123\x01'
    T.eq(notices(), {'NOTICE staff :\x01PING 123\x01'}, 'answered')
end)

T.case('talk, close and list', function()
    local c, chat = boot()
    T.command 'talk #new'
    local sent = c:take()
    T.eq(sent, {'CHATHISTORY LATEST #new * 50', 'JOIN #new'}, 'history before join')
    T.command 'talk Carol'
    T.eq(c:take(), {'CHATHISTORY LATEST Carol * 50', 'MONITOR + Carol'}, 'monitor a nick')

    c:recv ':srv 730 me :Carol!c@h'
    chat.close('test', 'carol')
    T.eq(c:take(), {'MONITOR - carol'}, 'unmonitored')
    T.eq(chat.buffer('test', 'Carol'), nil, 'closed')

    T.command 'list'
    T.eq(c:take(), {'LIST'}, 'LIST')
    c:recv ':srv 321 me Channel :Users  Name'
    c:recv ':srv 322 me #a 12 :topic a'
    c:recv ':srv 322 me #b 3 :topic b'
    c:recv ':srv 323 me :End of /LIST'
    c:recv ':srv 322 me #late 1 :not listed'
    T.eq(chat.get('test').list.n, 2, 'two channels, nothing after the end')
end)

T.case('closing a channel parts it, and its buffer stays closed', function()
    local c, chat = boot()
    c:recv ':me!u@h JOIN #chan'
    c:take()
    T.command 'close #Chan'
    T.eq(c:take(), {'PART #Chan'}, 'parted')
    T.eq(chat.buffer('test', '#chan'), nil, 'closed at once')
    c:recv ':bob!b@h PRIVMSG #chan :before the part'
    T.ok(chat.buffer('test', '#chan'), 'reopened by a message in between')
    c:recv ':me!u@h PART #chan'
    T.eq(chat.buffer('test', '#chan'), nil, 'closed again by our PART')

    -- a part that wasn't /close keeps the buffer
    c:recv ':me!u@h JOIN #kept'
    c:recv ':me!u@h PART #kept'
    T.eq(texts(chat.buffer('test', '#kept')), {'JOIN #kept', 'PART #kept'}, 'kept, with the part')

    -- a close whose PART never came back is forgotten when we join again
    c:recv ':me!u@h JOIN #again'
    chat.close('test', '#again')
    c:recv ':me!u@h JOIN #again'
    c:recv ':me!u@h PART #again'
    T.ok(chat.buffer('test', '#again'), 'rejoined, then parted: kept')

    -- a buffer for a channel we aren't in only closes
    chat.open('test', '#gone')
    c:take()
    chat.close('test', '#gone')
    T.eq(c:take(), {}, 'no PART')
end)

T.case('topic sets and clears, and Tab offers the current one to edit', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    control.init_state(HUB.state)
    local cmdline = T.require 'hub.ui.cmdline'
    local editor = T.require 'hub.ui.editor'
    local keymap = T.require 'hub.ui.keymap'
    c:recv ':me!u@h JOIN #chan'
    c:recv ':srv 332 me #chan :old topic'
    c:recv ':srv 353 me = #chan :@me bob'
    c:take()
    control.set_talk_target('test', '#chan')

    cmdline.execute 'topic new topic'
    T.eq(c:take(), {'TOPIC #chan :new topic'}, 'set')
    cmdline.execute 'topic'
    T.eq(c:take(), {'TOPIC #chan :'}, 'cleared')

    local input = HUB.state.ui.input
    input.mode = 'command'
    local function tab(typed)
        editor.reset(input.editor)
        for _, ch in utf8.codes(typed) do editor.add(input.editor, ch) end
        keymap.input[keymap.ctrl 'I']()
        return editor.content(input.editor)
    end
    T.eq(tab 'topic ', 'topic old topic', 'the current topic')
    T.eq(tab 'topic b', 'topic bob', 'after that, nicks')
    T.eq(tab 'topic@test ', 'topic@test old topic', 'naming the network')
    c:recv ':srv TOPIC #chan :'
    T.eq(tab 'topic ', 'topic #chan', 'no topic: channels and nicks')
end)

T.case('op, deop, voice and devoice nicks, or ourselves', function()
    local c = boot()
    c:recv ':me!u@h JOIN #chan'
    c:take()

    T.command('op a b c d', nil, '#chan')
    T.eq(c:take(), {'MODE #chan +ooo a b c', 'MODE #chan +o d'}, 'three to a line by default')
    c:recv ':srv 005 me MODES=4 :are supported'
    T.command('devoice a b c d e', nil, '#chan')
    T.eq(c:take(), {'MODE #chan -vvvv a b c d', 'MODE #chan -v e'}, 'as many as MODES')
    c:recv ':srv 005 me MODES :are supported'
    T.command('voice a b c d e', nil, '#chan')
    T.eq(c:take(), {'MODE #chan +vvvvv a b c d e'}, 'MODES without a limit')

    T.command('op', nil, '#chan')
    T.eq(c:take(), {'PRIVMSG ChanServ :OP #chan'}, 'op ourselves through ChanServ')
    T.command('voice', nil, '#chan')
    T.eq(c:take(), {'PRIVMSG ChanServ :VOICE #chan'}, 'voice ourselves through ChanServ')
    T.command('deop', nil, '#chan')
    T.eq(c:take(), {'MODE #chan -o me'}, 'deop ourselves directly')
    T.command('devoice', nil, '#chan')
    T.eq(c:take(), {'MODE #chan -v me'}, 'devoice ourselves directly')
end)

T.case('mode changes the shown channel, checked against CHANMODES, or shows it', function()
    local c = boot()
    local bus = T.require 'hub.runtime.bus'
    c:recv ':srv 005 me PREFIX=(ov)@+ CHANMODES=bq,k,l,imnst MODES=2 :are supported'
    c:recv ':me!u@h JOIN #chan'
    c:take()
    local shown = {}
    bus.on(HUB.current.bus, 'chat.show_channel', 'test', function(ev) table.insert(shown, ev.target) end)

    T.command('mode +nt-s', nil, '#chan')
    T.eq(c:take(), {'MODE #chan +nt-s'}, 'flags')
    T.command('mode +kl key 50', nil, '#chan')
    T.eq(c:take(), {'MODE #chan +kl key 50'}, 'arguments in order')
    T.command('mode -l+o-k bob key', nil, '#chan')
    T.eq(c:take(), {'MODE #chan -l+o-k bob key'}, 'unset l takes none; k does')
    T.command('mode +ooo-v a b c d', nil, '#chan')
    T.eq(c:take(), {'MODE #chan +oo a b', 'MODE #chan +o-v c d'}, 'as many arguments a line as MODES')
    T.command('mode i', nil, '#chan')
    T.eq(c:take(), {'MODE #chan +i'}, 'no sign: sets, as the server reads it')

    for bad, why in pairs {
        ['mode +x'] = 'not a channel mode here: x',
        ['mode +k'] = '+k needs an argument',
        ['mode +n extra'] = 'more arguments than the modes take: extra',
        ['mode +'] = 'no modes: +',
    } do
        T.command(bad, nil, '#chan')
        T.eq(c:take(), {}, 'unsent: ' .. bad)
        local errors = T.log_lines 'error'
        T.eq(errors[#errors], 'mode: ' .. why, 'refused')
    end

    T.command('mode', nil, '#chan')
    T.eq(c:take(), {'MODE #chan'}, 'none: modes asked for again')
    T.command('mode +bq', nil, '#chan')
    T.eq(c:take(), {'MODE #chan +b', 'MODE #chan +q'}, 'only lists: fetched')
    T.eq(shown, {'#chan', '#chan'}, 'and shown')
end)

T.case('Tab after mode offers what fits the argument', function()
    local c = boot()
    c:recv ':srv 005 me PREFIX=(ov)@+ CHANMODES=bq,k,l,imnst :are supported'
    c:recv ':me!u@h JOIN #chan'
    c:recv ':srv 353 me = #chan :@me bob'
    c:recv ':srv 324 me #chan +k sekrit'
    c:take()

    T.eq(T.complete_args('mode +o ', 'b', nil, '#chan'), {'bob'}, 'nicks for a prefix mode')
    T.eq(T.complete_args('mode +lo 5 ', 'b', nil, '#chan'), {'bob'}, 'past earlier arguments')
    T.eq(T.complete_args('mode -k ', '', nil, '#chan'), {'sekrit'}, 'the key to unset')
    T.eq(T.complete_args('mode +b ', '', nil, '#chan'), nil, 'nothing for a mask to set')
    T.eq(T.complete_args('mode -b ', '', nil, '#chan'), nil, 'a list not fetched')
    T.eq(c:take(), {'MODE #chan +b'}, 'is asked for')
    c:recv ':srv 367 me #chan *!*@bad.example op 1700000000'
    c:recv ':srv 368 me #chan :End of Channel Ban List'
    T.eq(T.complete_args('mode -b ', '', nil, '#chan'), {'*!*@bad.example'}, 'its masks')
end)

T.case('Tab after unban offers the ban list, fetching it first', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    control.init_state(HUB.state)
    local editor = T.require 'hub.ui.editor'
    local keymap = T.require 'hub.ui.keymap'
    c:recv ':me!u@h JOIN #chan'
    c:recv ':srv 353 me = #chan :@me bob'
    c:take()
    control.set_talk_target('test', '#chan')

    local input = HUB.state.ui.input
    input.mode = 'command'
    local function tab(typed)
        editor.reset(input.editor)
        for _, ch in utf8.codes(typed) do editor.add(input.editor, ch) end
        keymap.input[keymap.ctrl 'I']()
        return editor.content(input.editor)
    end
    T.eq(tab 'unban *', 'unban *', 'nothing yet')
    T.eq(c:take(), {'MODE #chan +b'}, 'the list asked for')
    c:recv ':srv 367 me #chan *!*@bad.example op 1700000000'
    c:recv ':srv 368 me #chan :End of Channel Ban List'
    T.eq(tab 'unban *', 'unban *!*@bad.example', 'a mask')
    T.eq(tab 'unban b', 'unban bob', 'a nick')
    T.eq(c:take(), {}, 'fetched once')
end)

T.case('Tab after close offers buffers, and after sasl credentials', function()
    local c = boot {sasl = {credentials = {
        {mechanism = 'EXTERNAL'},
        {name = 'main', mechanism = 'PLAIN', username = 'u', password = 'p'},
    }}}
    c:recv ':me!u@h JOIN #chan'
    c:recv ':me!u@h JOIN #other'
    c:recv ':bob!b@h PRIVMSG me :hi'
    local function sorted(t) table.sort(t) return t end
    T.eq(sorted(T.complete_args('close ', '#')), {'#chan', '#other'}, 'channels')
    T.eq(T.complete_args('close ', 'b'), {'bob'}, 'queries')
    T.eq(T.complete_args('close #chan ', ''), nil, 'one target')
    T.eq(sorted(T.complete_args('sasl ', '')), {'EXTERNAL', 'main'}, 'credentials by name')
    T.eq(T.complete_args('sasl ', 'm'), {'main'}, 'matching')
end)

T.case('channel ban mask rules', function()
    boot()
    local masks = T.require 'hub.features.chat.masks'
    T.eq(masks('~0a000001', '10.0.0.1', '10.0.0.1'), '*@10.0.0.1', 'simple')
    T.eq(masks('user', '10.0.0.1', 'localhost.localdomain'), 'user@10.0.0.1', 'no cloak with rDNS')
    T.eq(masks('user', '10.0.0.1', '10.0.0.1'), 'user@10.0.0.1', 'no cloak no rDNS')
    T.eq(masks('~user', '10.0.0.1', 'localhost.localdomain'), '*@10.0.0.1', 'no identd')
    T.eq(masks('~user', '10.0.0.1', 'unaffiliated/spammer'), '*@unaffiliated/spammer', 'cloak without identd')
    T.eq(masks('user', '10.0.0.1', 'unaffiliated/spammer'), '*@unaffiliated/spammer', 'cloak with identd')
    T.eq(masks('~user', '2001:470:7857:c::6667', '2001:470:7857:c::6667'), '*@2001:470:7857:c::6667', 'ipv6')
    T.eq(masks('user', '192.0.2.1', 'gateway/tor-sasl/user'), '*@gateway/tor-sasl/user', 'gateway, like a cloak')
    T.eq(masks('uid12345', '255.255.255.255', 'id-12345.ilkley.irccloud.com'), '?id12345@*.irccloud.com', 'IRCCloud')
    T.eq(masks('~user', '255.255.255.255', 'host.example'), '*@host.example', 'address hidden')
end)

T.case('quiet, ban, kickban and their removal in the shown channel', function()
    local c = boot()
    c:recv ':me!u@h JOIN #chan'
    c:recv ':srv 353 me = #chan :@me bob'
    c:take()

    T.command('ban $a:spammer', nil, '#chan')
    T.command('quiet *!*@bad.example', nil, '#chan')
    T.eq(c:take(), {'MODE #chan +b $a:spammer', 'MODE #chan +q *!*@bad.example'}, 'masks and extbans as given')
    T.command('mode +bb :x y', nil, '#chan')
    T.eq(c:take(), {}, 'a typed argument starting with : is refused')
    T.eq(T.tracebacks(), {}, 'as a user error')

    T.command('quiet Bob', nil, '#chan')
    T.eq(c:take(), {'WHO Bob %tuihn,696'}, 'looked up')
    c:recv ':srv 354 me 696 ~b 255.255.255.255 unaffiliated/bob bob'
    T.eq(c:take(), {'MODE #chan +q *!*@unaffiliated/bob'}, 'quieted by cloak')

    T.command('kickban bob go away', nil, '#chan')
    c:recv ':srv 354 me 696 b 192.0.2.5 host.example bob'
    T.eq(c:take(), {'WHO bob %tuihn,696', 'MODE #chan +b *!b@192.0.2.5', 'KICK #chan bob :go away'}, 'kickban')

    T.command('kickban Gone', nil, '#chan')
    c:recv ':srv 315 me Gone :End of WHO'
    c:recv ':srv 314 me Gone g gone.example * :Gone'
    c:recv ':srv 369 me Gone :End of WHOWAS'
    T.eq(c:take(), {'WHO Gone %tuihn,696', 'WHOWAS Gone 1', 'MODE #chan +b *!*@gone.example', 'KICK #chan Gone'},
        'someone who left, by WHOWAS')

    T.command('unban *!*@old.example', nil, '#chan')
    T.eq(c:take(), {'MODE #chan -b *!*@old.example'}, 'a mask as given')
    T.command('unquiet bob', nil, '#chan')
    c:recv ':srv 354 me 696 ~b 255.255.255.255 unaffiliated/bob bob'
    T.eq(c:take(), {'WHO bob %tuihn,696', 'MODE #chan -q *!*@unaffiliated/bob'}, 'a nick by its mask')

    T.command('ban nobody', nil, '#chan')
    c:recv ':srv 315 me nobody :End of WHO'
    c:recv ':srv 406 me nobody :There was no such nickname'
    T.eq(c:take(), {'WHO nobody %tuihn,696', 'WHOWAS nobody 1'}, 'WHO, then WHOWAS')
    T.eq(T.log_lines 'chat', {'Failed to find nobody'}, 'not found')
    T.eq(next(HUB.tasks), nil, 'finished')

    -- whether we may is the server's to say
    c:recv ':srv MODE #chan -o me'
    T.command('unban *!*@old.example', nil, '#chan')
    T.eq(c:take(), {'MODE #chan -b *!*@old.example'}, 'sent unopped')
    T.command('quiet bob', nil, 'bob')
    local errors = T.log_lines 'error'
    T.ok(errors[#errors]:find 'not a channel: bob', 'refused outside a channel')
    T.eq(c:take(), {}, 'nothing sent')
end)

T.case('mentions notify once until seen, and dismiss', function()
    local c, chat = boot(nil, {notifications = {backend = 'test'}})
    -- a backend that records what it was asked
    local calls = {}
    HUB.current.gen.loaded['hub.features.notify.test'] = {
        notify = function(previous, target, nick, text, net, key)
            table.insert(calls, {'notify', previous or false, target, nick, text, net, key})
            return previous or 'handle'
        end,
        dismiss = function(handle) table.insert(calls, {'dismiss', handle}) end,
    }
    local notify = T.require 'hub.features.notify'
    notify.register_backend('test', 'hub.features.notify.test')
    local tty = T.require 'hub.runtime.tty'
    tty.set_focus(false)

    c:recv ':bob!b@h PRIVMSG me :one'
    c:recv ':bob!b@h PRIVMSG me :two'
    T.eq(calls, {
        {'notify', false, 'bob', 'bob', 'one', 'test', 'BOB'},
        {'notify', 'handle', 'bob', 'bob', 'two', 'test', 'BOB'},
    }, 'second notification knows the first')

    tty.set_focus(true)
    c:recv ':bob!b@h PRIVMSG me :three'
    T.eq(#calls, 2, 'no notifications while focused')

    notify.dismiss('test', 'BOB')
    T.eq(calls[3], {'dismiss', 'handle'}, 'dismissed by folded name')
    notify.dismiss('test', 'bob')
    T.eq(#calls, 3, 'only once')
    T.eq(chat.buffer('test', 'bob').mention, true, 'the buffer still shows the mention')
end)

T.case('mac notifications group by network and buffer, with a plain subtitle', function()
    boot()
    local mac = T.require 'hub.features.notify.mac'
    local runs = {}
    local methods = HUB.current.task_methods
    local execute = methods.execute
    methods.execute = function(_, command, args) table.insert(runs, {command, args}) return 0, '', '' end
    local ok, err = pcall(function()
        T.eq(mac.notify(nil, '[afk]bob', 'bob', 'hi', 'test', '{AFK}BOB'), 'irc.snowcone.test.{AFK}BOB', 'the group')
    end)
    methods.execute = execute
    assert(ok, err)
    local args = runs[1][2]
    local subtitle
    for i, a in ipairs(args) do if a == '-subtitle' then subtitle = args[i + 1] end end
    T.eq(subtitle, 'test [afk]bob', 'starts with the network')
end)

T.case('crypto commands write keys and print the services commands', function()
    boot()
    local dir = os.tmpname()
    os.remove(dir)
    local path = require 'pl.path'
    path.mkdir(dir)

    T.command 'x25519_new'
    local lines = T.log_lines 'crypto'
    T.eq(T.log_lines 'error', {}, 'no errors')
    T.ok(lines[#lines]:match '^/msg NickServ SET X25519%-PUBKEY %S+$', lines[#lines])
    T.eq(#lines, 1, 'only the services command is logged')
    local entry
    for e in T.require 'hub.lib.OrderedMap'.each(HUB.state.log) do
        if e.category == 'crypto' then entry = e break end
    end
    T.eq(entry.detail, nil, 'a plain line')

    local prompts = {}
    T.require 'hub.runtime.bus'.on(HUB.current.bus, 'task.prompt', 'test', function(ev)
        table.insert(prompts, ev)
    end)
    T.command('cert_new ' .. dir .. '/cert.pem')
    T.eq(#prompts, 1, 'asked for a password')
    T.require 'hub.runtime.task'.answer(prompts[1].task, '')
    lines = T.log_lines 'crypto'
    local added = lines[#lines]
    T.ok(added:match '^/msg NickServ CERT ADD %x+$', added)

    T.command('cert_fp ' .. dir .. '/cert.pem')
    lines = T.log_lines 'crypto'
    T.eq(lines[#lines], added, 'same fingerprint from the file')

    T.eq(require 'lfs'.attributes(dir .. '/cert.pem', 'permissions'), 'rw-------', 'only we can read the key')
    local before = require 'pl.file'.read(dir .. '/cert.pem')
    T.command('cert_new ' .. dir .. '/cert.pem')
    local ok, err = pcall(T.require 'hub.runtime.task'.answer, prompts[2].task, '')
    T.ok(not ok and tostring(err):find 'File exists', 'an existing file is refused')
    T.eq(require 'pl.file'.read(dir .. '/cert.pem'), before, 'and left alone')

    os.remove(dir .. '/cert.pem')
    path.rmdir(dir)
end)

T.run()
