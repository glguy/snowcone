-- The protocol model (net/irc.lua) as the handlers (net/handlers.lua)
-- keep it: channel modes and lists, members and who is in view, away,
-- ISUPPORT, our own state, batches and a bouncer's networks.
--
-- Run with:  snowcone tests/hub/test-model.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local N = dofile(here .. '/netlib.lua')(T)
local network, boot, rec, record, register = N.network, N.boot, N.rec, N.record, N.register

-- A PREFIX other than the default, and modes of every CHANMODES type
local test_isupport <const> = 'CHANTYPES=# PREFIX=(qaohv)~&@%+ CHANMODES=beI,k,fl,imnst'

local function registered(extra, isupport_line)
    local fake = T.boot_networks {T.network('test', extra)}
    local c = fake.last()
    T.register(c, {isupport = isupport_line or test_isupport})
    return c
end

local function model()
    return T.require 'hub.net.irc'
end

local function joined(name)
    return model().get_channel(rec().irc, name)
end

-- Prefix modes of each member of a channel, by nick as kept
local function member_modes(name)
    local modes = {}
    for _, member in pairs(joined(name).members) do
        local letters = {}
        for m in pairs(member.modes) do table.insert(letters, m) end
        table.sort(letters)
        modes[member.user.nick] = table.concat(letters)
    end
    return modes
end

-- Join #c with alice, bob, carol, dave and eve, prefixed from NAMES
local function join(c)
    c:recv ':me!u@h JOIN #c'
    c:recv ':srv 353 me = #c :~me &alice @bob %carol +dave eve'
    c:recv ':srv 366 me #c :End of /NAMES list.'
end

-----------------------------------------------------------------------
-- Channel modes

T.case('NAMES prefixes map through PREFIX', function()
    local c = registered()
    join(c)
    T.eq(member_modes '#c', {me = 'q', alice = 'a', bob = 'o', carol = 'h', dave = 'v', eve = ''}, 'members')
end)

T.case('MODE arguments line up while the channel modes are unknown', function()
    local c = registered()
    join(c)
    T.eq(joined('#c').modes, nil, 'not fetched')
    -- each mode before +o takes or leaves an argument by its type
    c:recv ':bob!u@h MODE #c +bo mask!*@* eve'
    c:recv ':bob!u@h MODE #c +vo ghost alice'
    c:recv ':bob!u@h MODE #c +ko key carol'
    c:recv ':bob!u@h MODE #c +lo 10 dave'
    c:recv ':bob!u@h MODE #c -lo dave'
    c:recv ':bob!u@h MODE #c +io eve'
    T.eq(member_modes '#c', {me = 'q', alice = 'ao', bob = 'o', carol = 'ho', dave = 'v', eve = 'o'},
        'each +o reached the member named for it')
    c:recv ':me!u@h MODE #c +qah-a eve dave carol alice'
    T.eq(member_modes '#c', {me = 'q', alice = 'o', bob = 'o', carol = 'ho', dave = 'av', eve = 'oq'},
        'every PREFIX mode takes its member')
    T.eq(joined('#c').modes, nil, 'still not known')
    T.eq(rec().intent.channels, {{name = '#c', key = 'key'}}, 'the key to rejoin with')
end)

T.case('MODE changes known channel modes, by type', function()
    local c = registered()
    join(c)
    c:recv ':srv 324 me #c +ntkl key 10'
    T.eq(joined('#c').modes, {n = true, t = true, k = 'key', l = '10'}, 'from RPL_CHANNELMODEIS')
    T.eq(rec().intent.channels, {{name = '#c', key = 'key'}}, 'its key to rejoin with')

    c:recv ':bob!u@h MODE #c +if-lt #fwd'
    T.eq(joined('#c').modes, {n = true, i = true, k = 'key', f = '#fwd'}, 'D set and cleared, C set and cleared')
    c:recv ':bob!u@h MODE #c -k+k key newkey'
    T.eq(joined('#c').modes.k, 'newkey', 'B always takes its argument')
    T.eq(rec().intent.channels, {{name = '#c', key = 'newkey'}}, 'the new key')
    c:recv ':bob!u@h MODE #c -k *'
    T.eq(joined('#c').modes.k, nil, 'key removed')
    T.eq(rec().intent.channels, {{name = '#c'}}, 'no key to rejoin with')
end)

T.case('list modes arrive by their own replies, one list at a time', function()
    local c = registered(nil, 'CHANTYPES=# CHANMODES=beIq,k,l,imnst')
    c:recv ':me!u@h JOIN #c'
    c:recv ':srv 367 me #c ban1!*@* op 1700000001'
    c:recv ':srv 367 me #c ban2!*@* op 1700000002'
    c:recv ':srv 368 me #c :End of Channel Ban List'
    c:recv ':srv 728 me #c q quiet!*@* op 1700000003'
    c:recv ':srv 729 me #c q :End of Channel Quiet List'
    c:recv ':srv 348 me #c except!*@* op 1700000004'
    c:recv ':srv 349 me #c :End of Channel Exception List'
    c:recv ':srv 346 me #c invited!*@* op 1700000005'
    c:recv ':srv 347 me #c :End of Channel Invite List'
    local lists = joined('#c').list_modes
    T.eq(lists.b, {
        ['ban1!*@*'] = {who = 'op', ts = '1700000001'},
        ['ban2!*@*'] = {who = 'op', ts = '1700000002'},
    }, 'bans')
    T.eq(lists.q, {['quiet!*@*'] = {who = 'op', ts = '1700000003'}}, 'quiets, with the mode before the mask')
    T.eq(lists.e, {['except!*@*'] = {who = 'op', ts = '1700000004'}}, 'exceptions, none of the bans')
    T.eq(lists.I, {['invited!*@*'] = {who = 'op', ts = '1700000005'}}, 'invites')

    c:recv ':op!u@h MODE #c +b-b new!*@* ban1!*@*'
    T.eq(lists.b['new!*@*'], {who = 'op!u@h'}, 'added, by whom')
    T.eq(lists.b['ban1!*@*'], nil, 'removed')
end)

-----------------------------------------------------------------------
-- Members

T.case('a KICK takes the member out; ours takes the channel', function()
    local c = registered()
    join(c)
    c:recv ':bob!u@h KICK #c alice :bye'
    T.eq(joined('#c').members.ALICE, nil, 'alice kicked')
    T.eq(model().find_user(rec().irc, 'alice'), nil, 'and out of view')
    c:recv ':bob!u@h KICK #c me :you too'
    T.eq(joined('#c'), nil, 'we left')
    T.eq(rec().intent.channels, {}, 'not to be rejoined')
end)

T.case('a JOIN of a channel we are in starts it again', function()
    local c = registered()
    join(c)
    c:recv ':me!u@h JOIN #c'
    T.eq(member_modes '#c', {me = ''}, 'only what this join brings')
    T.eq(model().find_user(rec().irc, 'alice'), nil, 'and the members before it are out of view')
end)

T.case('a QUIT and a NICK carry the channels they affected, sorted', function()
    local c = registered()
    local seen = {}
    T.require 'hub.runtime.bus'.on(HUB.current.bus, 'irc.message', 'test', function(ev)
        if ev.msg.command == 'QUIT' or ev.msg.command == 'NICK' then table.insert(seen, ev.msg.channels) end
    end)
    for _, name in ipairs {'#b', '#a', '#c'} do
        c:recv(':me!u@h JOIN ' .. name)
    end
    c:recv ':alice!u@h JOIN #b'
    c:recv ':alice!u@h JOIN #a'
    c:recv ':alice!u@h NICK alicia'
    c:recv ':alicia!u@h QUIT :bye'
    T.eq(seen, {{'#a', '#b'}, {'#a', '#b'}}, 'channels')
end)

-----------------------------------------------------------------------
-- ISUPPORT

T.case('CASEMAPPING selects how names fold, and an unknown one is rfc1459', function()
    local c = registered()
    local irc = rec().irc
    local fold = model().fold
    T.eq(fold(irc, 'a{~'), 'A[^', 'rfc1459 before any')
    c:recv ':srv 005 me CASEMAPPING=rfc1459-strict :are supported'
    T.eq(fold(irc, 'a{~'), 'A[~', 'rfc1459-strict leaves ~ alone')
    c:recv ':srv 005 me CASEMAPPING=ascii :are supported'
    T.eq(fold(irc, 'a{~'), 'A{~', 'ascii folds letters only')
    c:recv ':srv 005 me CASEMAPPING=rfc7613 :are supported'
    T.eq(irc.casemapping, 'rfc1459', 'an unknown mapping')
end)

T.case('INVEX names its mode, I without a value; CHATHISTORY=0 sets no limit', function()
    local c = registered()
    local irc = rec().irc
    c:recv ':srv 005 me INVEX CHATHISTORY=50 :are supported'
    T.eq({irc.invex, irc.max_chat_history}, {'I', 50}, 'bare INVEX and a limit')
    c:recv ':srv 005 me INVEX=J CHATHISTORY=0 :are supported'
    T.eq({irc.invex, irc.max_chat_history}, {'J', nil}, 'named, and no limit')
end)

-----------------------------------------------------------------------
-- Our own state

T.case('user modes follow MODE and RPL_UMODEIS, signs and all', function()
    local c = registered()
    local irc = rec().irc
    c:recv ':srv 221 me +iw'
    T.eq(irc.mode, {i = true, w = true}, 'replaced by RPL_UMODEIS')
    c:recv ':me MODE me :-i+Z-w+x'
    T.eq(irc.mode, {Z = true, x = true}, 'each sign applies to the letters after it')
end)

T.case('the account follows logging in and out; SASL mechanisms follow 908', function()
    local c = registered()
    local irc = rec().irc
    c:recv ':srv 900 me me!u@h acct :You are now logged in as acct'
    T.eq(irc.account, 'acct', 'logged in')
    c:recv ':srv 901 me me!u@h :You are now logged out'
    T.eq(irc.account, nil, 'logged out')
    c:recv ':srv 908 me PLAIN,EXTERNAL :are available SASL mechanisms'
    T.eq(irc.sasl_mechs, {PLAIN = true, EXTERNAL = true}, 'mechanisms')
end)

T.case('our user@host follows our messages, CHGHOST and RPL_HOSTHIDDEN', function()
    local c = registered()
    local irc = rec().irc
    c:recv ':me!u@h JOIN #c'
    T.eq(irc.userhost, 'u@h', 'from our own message')
    c:recv ':srv 396 me cloak/me :is now your hidden host'
    T.eq(irc.userhost, 'u@cloak/me', 'a host replaces the host')
    c:recv ':srv 396 me ident@vhost :is now your hidden host'
    T.eq(irc.userhost, 'ident@vhost', 'user@host replaces both')
    c:recv ':me!ident@vhost CHGHOST new newhost'
    T.eq(irc.userhost, 'new@newhost', 'CHGHOST')
end)

T.case('a channel\'s creation time and topic replies', function()
    local c = registered()
    c:recv ':me!u@h JOIN #c'
    c:recv ':srv 332 me #c :the topic'
    c:recv ':srv 333 me #c setter 1700000000'
    c:recv ':srv 329 me #c 1600000000'
    local ch = joined '#c'
    T.eq({ch.topic, ch.topic_who, ch.topic_time, ch.creationtime},
        {'the topic', 'setter', 1700000000, 1600000000}, 'kept')
    c:recv ':srv 331 me #c :No topic is set'
    T.eq({ch.topic, ch.topic_who, ch.topic_time}, {'', nil, nil}, 'no topic')
end)

-----------------------------------------------------------------------
-- Model functions

T.case('message_time reads server-time as UTC, early months and leap days too', function()
    registered()
    local message_time = model().message_time
    T.eq(message_time {tags = {time = '2024-02-29T00:00:00.000Z'}}, 1709164800, 'a leap day')
    T.eq(message_time {tags = {time = '2025-01-01T00:00:01Z'}}, 1735689601, 'January, without fractions')
    local before = os.time()
    T.ok(message_time {tags = {time = '2024-13-01T00:00:00Z'}} >= before, 'no thirteenth month: now')
    T.ok(message_time {tags = {}} >= before, 'no tag: now')
end)

T.case('the nicks we sent are kept to a bound, and taken in order', function()
    registered()
    local irc_model, irc = model(), rec().irc
    irc.nicks_sent = nil
    for i = 1, 9 do irc_model.note_nick_sent(irc, 'n' .. i) end
    T.eq(irc_model.take_nick_sent(irc, 'n1'), false, 'the oldest was dropped')
    T.eq(irc_model.take_nick_sent(irc, 'n5'), true, 'one we sent')
    T.eq(irc.nicks_sent, {'n6', 'n7', 'n8', 'n9'}, 'with those sent before it')
    T.eq(irc_model.take_nick_sent(irc, 'N9'), true, 'in any case')
    T.eq(irc.nicks_sent, {}, 'none left')
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

-- Drive registration with these capabilities acknowledged
local function register_caps(c, caps, isupport)
    c:con()
    c:recv(':srv CAP * LS :' .. caps)
    c:recv(':srv CAP me ACK :' .. caps)
    c:recv ':srv 001 me :Welcome'
    c:recv(':srv 005 me ' .. (isupport or 'CHANTYPES=#') .. ' :are supported')
    c:recv ':srv 376 me :End of MOTD'
end

-- Every user record is in view, and every member's record is the user's
local function check_view(irc)
    for key, user in pairs(irc.users) do
        local seen = irc.monitor and irc.monitor[key] and irc.monitor[key].user == user
        for _, channel in pairs(irc.channels) do
            local member = channel.members[key]
            if member then
                T.ok(member.user == user, 'one record for ' .. key)
                seen = true
            end
        end
        T.ok(seen, key .. ' in view')
    end
    for _, channel in pairs(irc.channels) do
        for key, member in pairs(channel.members) do
            T.ok(irc.users[key] == member.user, key .. ' recorded')
        end
    end
end

-- The folded nicks of the users in view, sorted
local function in_view(irc)
    local keys = {}
    for key in pairs(irc.users) do table.insert(keys, key) end
    table.sort(keys)
    return keys
end

T.case('users are in view exactly while a channel or MONITOR keeps them', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c, 'me', 'CHANTYPES=# MONITOR=100')
    local irc = assert(rec().irc)
    c:recv ':me!u@h JOIN #a'
    c:recv ':srv 353 me = #a :me alice bob erin'
    c:recv ':me!u@h JOIN #b'
    c:recv ':srv 353 me = #b :me alice erin'
    check_view(irc)
    T.eq(in_view(irc), {'ALICE', 'BOB', 'ERIN', 'ME'}, 'from NAMES')

    c:recv ':bob!u@h PART #a'
    T.eq(irc.users.BOB, nil, 'gone with their only channel')
    c:recv ':erin!u@h NICK Fay'
    check_view(irc)
    T.eq(in_view(irc), {'ALICE', 'FAY', 'ME'}, 'renamed')
    T.ok(irc.channels['#A'].members.FAY.user == irc.channels['#B'].members.FAY.user, 'one record')
    c:recv ':fay!u@h NICK FAY'
    T.eq(irc.users.FAY.nick, 'FAY', 'a change of case keeps the record')

    c:recv ':me!u@h PART #a'
    check_view(irc)
    T.eq(in_view(irc), {'ALICE', 'FAY', 'ME'}, 'kept by #b')
    c:recv ':op!u@h KICK #b me :out'
    T.eq(in_view(irc), {}, 'no channel, no one')

    c:recv ':srv 730 me :carol!c@h,dave!d@h'
    check_view(irc)
    T.eq(in_view(irc), {'CAROL', 'DAVE'}, 'online by MONITOR')
    c:recv ':srv 731 me :carol'
    T.eq(in_view(irc), {'DAVE'}, 'offline')
    c:recv ':me!u@h JOIN #a'
    c:recv ':srv 353 me = #a :me dave'
    c:recv ':dave!d@h QUIT :bye'
    T.eq(in_view(irc), {'ME'}, 'quit')
    T.eq(irc.monitor.DAVE, {}, 'offline on MONITOR too')

    c:recv ':srv 730 me :dave!d@h'
    T.require 'hub.net.irc'.del_monitor(irc, 'dave')
    T.eq(irc.users.DAVE, nil, 'unwatched')
    c:recv ':srv 730 me :zed!z@h'
    c:recv ':srv 005 me -MONITOR :are supported'
    T.eq(irc.users.ZED, nil, 'MONITOR withdrawn, no one online by it')
end)

T.case('away is known while away-notify keeps it current, and only then', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register_caps(c, 'away-notify')
    local irc = assert(rec().irc)
    c:recv ':me!u@h JOIN #a'
    c:recv ':srv 353 me = #a :me alice'
    T.eq(irc.users.ALICE.away, nil, 'unknown from NAMES')
    c:recv ':srv 301 me alice :at lunch'
    T.eq(irc.users.ALICE.away, 'at lunch', 'known from RPL_AWAY')
    c:recv ':alice!a@h AWAY'
    T.eq(irc.users.ALICE.away, false, 'back')

    c:recv ':bob!b@h JOIN #a'
    T.eq(irc.users.BOB.away, false, 'here on joining')
    c:recv ':bob!b@h AWAY :brb'
    T.eq(irc.users.BOB.away, 'brb', 'away')
    c:recv ':bob!b@h PART #a'
    c:recv ':bob!b@h JOIN #a'
    T.eq(irc.users.BOB.away, false, 'back while out of view: no AWAY follows the JOIN')
    c:recv ':bob!b@h AWAY :'
    T.eq(irc.users.BOB.away, false, 'an empty message is back')
    c:recv ':bob!b@h AWAY :brb'
    c:recv ':me!u@h JOIN #b'
    c:recv ':bob!b@h JOIN #b'
    T.eq(irc.users.BOB.away, 'brb', 'a JOIN while in view keeps what is known')

    c:recv ':srv 301 me zed :gone'
    T.eq(irc.users.ZED, nil, 'no record for a user out of view')

    c:recv ':srv CAP me DEL :away-notify'
    T.eq(irc.users.BOB.away, nil, 'unknown without away-notify')
    c:recv ':srv 301 me bob :brb'
    T.eq(irc.users.BOB.away, nil, 'a reply would not be kept current')
    c:recv ':carol!c@h JOIN #a'
    T.eq(irc.users.CAROL.away, nil, 'nor a JOIN')
end)

T.case('a monitored nick has an away state with extended-monitor', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register_caps(c, 'away-notify extended-monitor', 'CHANTYPES=# MONITOR=100')
    local irc = assert(rec().irc)
    c:recv ':srv 730 me :carol!c@h'
    T.eq(irc.users.CAROL.away, nil, 'unknown when online')
    c:recv ':carol!c@h AWAY :out'
    T.eq(irc.users.CAROL.away, 'out', 'kept current')
    c:recv ':me!u@h JOIN #a'
    c:recv ':carol!c@h JOIN #a'
    T.eq(irc.users.CAROL.away, 'out', 'already current when she joins')
    c:recv ':carol!c@h PART #a'
    T.eq(irc.users.CAROL.away, 'out', 'and after she parts')
    c:recv ':srv CAP me DEL :extended-monitor'
    T.eq(irc.users.CAROL.away, nil, 'unknown without extended-monitor')
end)

T.case('our own away state comes from the replies to AWAY', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c)
    local irc = assert(rec().irc)
    c:recv ':srv 306 me :You have been marked as being away'
    T.eq(irc.away, true, 'away')
    c:recv ':me!u@h JOIN #a'
    T.eq(irc.users.ME.away, true, 'carried into our record')
    c:recv ':srv 305 me :You are no longer marked as being away'
    T.eq({irc.away, irc.users.ME.away}, {false, false}, 'back')

    T.command 'quote AWAY :gone fishing'
    c:recv ':srv 306 me :You have been marked as being away'
    T.eq({irc.away, irc.users.ME.away}, {'gone fishing', 'gone fishing'}, 'with the message we sent')
end)

T.case('a topic change keeps the time the server says it happened', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c)
    c:recv ':me!u@h JOIN #a'
    c:recv '@time=2026-11-21T12:34:56.789Z :carol!c@h TOPIC #a :news'
    local channel = T.require 'hub.net.irc'.get_channel(rec().irc, '#a')
    T.eq({channel.topic, channel.topic_time}, {'news', 1795264496}, 'from server-time')
    local before = os.time()
    c:recv ':carol!c@h TOPIC #a :more'
    T.ok(channel.topic_time >= before, 'now, without one')
end)

T.case('the snomask goes with user mode s', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c)
    local irc = assert(rec().irc)
    c:recv ':me MODE me :+os'
    c:recv ':srv 008 me +bcFs :Server notice mask'
    T.eq(irc.snomask, '+bcFs', 'set')
    c:recv ':me MODE me :-os'
    T.eq({irc.oper, irc.snomask}, {nil, nil}, 'gone on deoper')
    c:recv ':me MODE me :+s'
    c:recv ':srv 008 me + :Server notice mask'
    T.eq(irc.snomask, nil, 'a bare + is none')
end)

T.case('a lopsided PREFIX and a NAMES word of only prefixes add no one', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c, 'me', 'PREFIX=(ov)@ CHANMODES=b,k,l,imnt')
    c:recv ':me!u@h JOIN #chan'
    c:recv ':srv 353 me = #chan :@ me'

    local irc_model = T.require 'hub.net.irc'
    local irc = assert(rec().irc)
    T.eq(irc.prefixes, '', 'PREFIX ignored')
    T.eq(irc_model.get_channel(irc, '#chan').members, {ME = irc_model.get_channel(irc, '#chan').members.ME},
        'only me')

    c:recv ':srv 005 me PREFIX=(ov)@+ :are supported'
    c:recv ':srv 353 me = #chan :@ +'
    T.eq(irc_model.get_channel(irc, '#chan').members[''], nil, 'no member without a nick')
end)

T.case('valueless ISUPPORT tokens are empty values, or flags', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c, 'me', 'CHANTYPES STATUSMSG PREFIX CHANMODES LINELEN EXCEPTS')
    local irc = assert(rec().irc)
    T.eq(irc.chantypes, '', 'no channel types')
    T.eq(irc.statusmsg, '', 'no STATUSMSG prefixes')
    T.eq(irc.prefixes, '', 'no prefixes')
    T.eq(irc.modes_A, '', 'no list modes')
    T.eq(irc.linelen, 512, 'default line length')
    T.eq(irc.excepts, 'e', 'EXCEPTS a flag')
    T.eq(irc.isupport.CHANTYPES, true, 'the token kept as sent')

    c:recv ':x!u@h PRIVMSG me :hello'
    c:recv ':x!u@h PRIVMSG #notachan :hello'
    T.eq(T.tracebacks(), {}, 'messages still handled')
end)

T.case('lines missing parameters change nothing and raise nothing', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c, 'me', 'PREFIX=(ov)@+ CHANMODES=b,k,l,imnt')
    c:recv ':me JOIN #x'
    local irc_model = T.require 'hub.net.irc'
    local irc = rec().irc
    T.ok(irc_model.get_channel(irc, '#x'), 'a bare-nick source joins')
    T.ok(irc_model.get_channel(irc, '#x').members.ME, 'as a member')

    for _, line in ipairs {
        ':srv BATCH',
        ':srv 353 me = #x',
        ':srv 353 me',
        ':me!u@h MODE #x +o',
        ':me!u@h MODE #x +b',
        ':me!u@h MODE #x',
        ':me!u@h MODE',
        ':x!u@h NICK',
        ':x!u@h JOIN',
        ':x!u@h PART',
        ':x!u@h KICK #x',
        ':srv 301 me',
        ':srv 005 me =x -',
        ':srv 008 me',
        ':srv 221 me',
        ':srv 324 me',
        ':srv 324 me #x',
        ':srv 332 me',
        ':srv 333 me',
        ':srv 366 me',
        ':srv 367 me #x',
        ':srv 368 me',
        ':srv 730 me',
        ':srv 731 me',
        ':srv 908 me',
    } do
        c:recv(line)
    end
    T.eq(T.tracebacks(), {}, 'no errors')
    T.eq(rec().phase, 'connected', 'still connected')
end)

T.case('ISUPPORT values are unescaped', function()
    local fake = boot {network('test')}
    register(fake.last(), 'me', 'NETWORK=Some\\x20Net')
    T.eq(rec().irc.isupport.NETWORK, 'Some Net', 'unescaped')
end)

T.case('user mode -o clears operator status, and o sets it again', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c)
    local opered = record 'irc.oper'
    c:recv ':me MODE me :+o'
    T.eq(#opered, 1, 'oper')
    c:recv ':me MODE me :-o'
    T.eq(rec().irc.oper, nil, 'no longer')
    c:recv ':srv 381 me :You are now an IRC operator'
    T.eq(#opered, 2, 'again')
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
    T.eq(#messages, 2, 'history: only the BATCH lines are individual messages')
    T.eq(rec().irc.batches, {}, 'closed batches are forgotten')
    c:recv ':srv BATCH +t draft/chathistory-targets'
    c:recv '@batch=t :x!u@h PRIVMSG #c :not live'
    c:recv ':srv BATCH -t'
    T.eq(#messages, 4, 'a chathistory-targets batch is history too')
end)

-- A soju network list: network 1, named libera and connected
local function bouncer_list(c)
    c:recv ':srv BATCH +b soju.im/bouncer-networks'
    c:recv '@batch=b :srv BOUNCER NETWORK 1 :name=libera;state=connected'
    c:recv ':srv BATCH -b'
end

T.case('bouncer network updates set and remove attributes', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c)
    bouncer_list(c)
    local networks = assert(rec().irc.bouncer_networks)
    T.eq(networks['1'], {name = 'libera', state = 'connected'}, 'listed')
    c:recv ':srv BOUNCER NETWORK 1 :state=disconnected;error=gone'
    T.eq(networks['1'], {name = 'libera', state = 'disconnected', error = 'gone'}, 'updated')
    c:recv ':srv BOUNCER NETWORK 1 :error;state='
    T.eq(networks['1'], {name = 'libera'}, 'no value removes, with or without =')
    c:recv ':srv BOUNCER NETWORK 1 *'
    T.eq(networks['1'], nil, 'deleted')
    c:recv ':srv BOUNCER NETWORK 2 :name=oftc'
    T.eq(networks['2'], {name = 'oftc'}, 'a new one')
end)

T.case('bad bouncer network attributes are reported, not applied', function()
    local fake = boot({network('test')}, {strict = false})
    local c = fake.last()
    register(c)
    bouncer_list(c)
    c:recv ':srv BOUNCER NETWORK 1 :name=other;'
    c:recv ':srv BOUNCER NETWORK 2 :name=new;'
    c:recv ':srv BOUNCER NETWORK 3'
    local networks = assert(rec().irc.bouncer_networks)
    T.eq(networks['1'], {name = 'libera', state = 'connected'}, 'unchanged')
    T.eq(networks['2'], nil, 'no record for a bad update')
    T.eq(networks['3'], nil, 'nor for a missing one')
    local reported = 0
    for _, line in ipairs(T.log_lines()) do
        T.ok(not line:find 'traceback', 'no traceback: ' .. line)
        if line:find 'bad BOUNCER NETWORK attributes' then reported = reported + 1 end
    end
    T.eq(reported, 3, 'each reported')
end)

T.case('a batch that is not a replay updates the model as it arrives', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c)
    c:recv ':me!u@h JOIN #c'
    c:recv ':srv 353 me = #c :me alice bob'
    local messages = record 'irc.message'
    c:recv ':srv BATCH +s1 netsplit hub.example leaf.example'
    c:recv '@batch=s1 :alice!a@h QUIT :hub.example leaf.example'
    T.eq(rec().irc.channels['#C'].members.ALICE, nil, 'gone before the batch ends')
    c:recv ':srv BATCH -s1'
    T.eq(#messages, 3, 'each line is an ordinary message too')
    T.eq(messages[2].msg.channels, {'#c'}, 'with the channels the user was in')
end)

T.case('replayed history never changes the connection', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c)
    c:recv ':me!u@h JOIN #c'
    c:recv ':srv 353 me = #c :me alice'
    local messages = record 'irc.message'
    local batches = record 'irc.batch'
    c:recv ':srv BATCH +h1 chathistory #c'
    c:recv '@batch=h1 :alice!a@h QUIT :long ago'
    c:recv '@batch=h1 :me!u@h NICK past_me'
    c:recv '@batch=h1 :srv BATCH +inner something'
    c:recv '@batch=inner :alice!a@h PART #c'
    c:recv '@batch=h1 :srv BATCH -inner'
    c:recv ':srv BATCH -h1'
    local irc = assert(rec().irc)
    T.ok(irc.channels['#C'].members.ALICE, 'alice still a member')
    T.eq(irc.nick, 'me', 'our nick unchanged')
    T.eq(#messages, 2, 'only the outer BATCH lines are messages')
    T.eq(#batches, 2, 'both batches emitted, the nested one first')
    T.eq(batches[2].type, 'chathistory', 'outer')
    T.eq(#batches[2].messages, 4, 'with its own lines, the nested BATCH lines included')
    T.eq(#batches[1].messages, 1, 'the nested batch has its line')
end)

T.case('our nick matches in any case the casemapping allows', function()
    local fake = boot {network('test', {identity = {nick = 'Me'}})}
    local c = fake.last()
    register(c, 'Me')
    c:recv ':me!u@h JOIN #c'
    T.ok(rec().irc.channels['#C'], 'joined although echoed as me')
    c:recv ':ME!u@h NICK Other'
    T.eq(rec().irc.nick, 'Other', 'our nick change recognized')
end)

T.case('OFTC hybrid quiet lists are 344 and 345', function()
    local fake = boot {network('test', {ircd = 'oftc-hybrid'})}
    local c = fake.last()
    register(c)
    c:recv ':me!u@h JOIN #c'
    c:recv ':srv 344 me #c *!*@loud.example op!o@h 1700000000'
    c:recv ':srv 345 me #c :End of Channel Quiet List'
    local irc_model = T.require 'hub.net.irc'
    local channel = irc_model.get_channel(rec().irc, '#c')
    T.eq(channel.list_modes.q, {['*!*@loud.example'] = {who = 'op!o@h', ts = '1700000000'}}, 'quiets')
    -- capture, not a quiet list
    c:recv ':srv 728 me victim :Is UnCaptured.'
    c:recv ':srv 729 me #c q :End of Channel Quiet List'
    T.eq(channel.list_modes.q, {['*!*@loud.example'] = {who = 'op!o@h', ts = '1700000000'}}, 'unchanged')
end)

T.run()
