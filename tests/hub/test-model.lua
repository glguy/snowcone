-- The protocol model (net/irc.lua) as the handlers (net/handlers.lua)
-- keep it: channel modes and lists, members, ISUPPORT, our own state.
--
-- Run with:  snowcone tests/hub/test-model.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')

-- A PREFIX other than the default, and modes of every CHANMODES type
local isupport <const> = 'CHANTYPES=# PREFIX=(qaohv)~&@%+ CHANMODES=beI,k,fl,imnst'

local function registered(extra, isupport_line)
    local fake = T.boot_networks {T.network('test', extra)}
    local c = fake.last()
    T.register(c, {isupport = isupport_line or isupport})
    return c
end

local function rec()
    return HUB.state.nets.test
end

local function model()
    return T.require 'hub.net.irc'
end

local function channel(name)
    return model().get_channel(rec().irc, name)
end

-- Prefix modes of each member of a channel, by nick as kept
local function member_modes(name)
    local modes = {}
    for _, member in pairs(channel(name).members) do
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
    T.eq(channel('#c').modes, nil, 'not fetched')
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
    T.eq(channel('#c').modes, nil, 'still not known')
    T.eq(rec().intent.channels, {{name = '#c', key = 'key'}}, 'the key to rejoin with')
end)

T.case('MODE changes known channel modes, by type', function()
    local c = registered()
    join(c)
    c:recv ':srv 324 me #c +ntkl key 10'
    T.eq(channel('#c').modes, {n = true, t = true, k = 'key', l = '10'}, 'from RPL_CHANNELMODEIS')
    T.eq(rec().intent.channels, {{name = '#c', key = 'key'}}, 'its key to rejoin with')

    c:recv ':bob!u@h MODE #c +if-lt #fwd'
    T.eq(channel('#c').modes, {n = true, i = true, k = 'key', f = '#fwd'}, 'D set and cleared, C set and cleared')
    c:recv ':bob!u@h MODE #c -k+k key newkey'
    T.eq(channel('#c').modes.k, 'newkey', 'B always takes its argument')
    T.eq(rec().intent.channels, {{name = '#c', key = 'newkey'}}, 'the new key')
    c:recv ':bob!u@h MODE #c -k *'
    T.eq(channel('#c').modes.k, nil, 'key removed')
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
    local lists = channel('#c').list_modes
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
    T.eq(channel('#c').members.ALICE, nil, 'alice kicked')
    T.eq(model().find_user(rec().irc, 'alice'), nil, 'and out of view')
    c:recv ':bob!u@h KICK #c me :you too'
    T.eq(channel('#c'), nil, 'we left')
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
    local ch = channel '#c'
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

T.run()
