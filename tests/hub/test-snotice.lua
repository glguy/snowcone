-- Golden replay of server notices.
--
-- Each fixtures/*.log is replayed through a fake network with the snotice
-- feature; the snote events must equal fixtures/*.expected.lua, which
-- tests/hub/tools/expect-snotes.lua wrote with the reference parser.
-- snotes-live.log comes from a live network through
-- tests/hub/tools/anonymize-snotes.lua; snotes-synthetic.log is written by
-- hand for notices that didn't occur.
--
-- Run with:  snowcone tests/hub/test-snotice.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local FakeTransport = dofile(here .. '/fake_transport.lua')

local fixtures = {'snotes-live', 'snotes-synthetic'}

-- Notice names the fixtures must cover between them
local required = {
    'connect', 'disconnect', 'nick', 'kline', 'xline', 'dline', 'resv',
    'filter', 'kline_active', 'dline_active', 'expired', 'removed',
    'rejected', 'netsplit', 'netjoin', 'kill', 'newmaxlocal', 'flooder',
    'spambot', 'targetchange', 'create_channel', 'operspy', 'override',
    'toomany', 'badlogin', 'oper', 'grant', 'ungrant', 'modload',
    'modunload', 'shedding_on', 'shedding_off',
}

local function boot(features)
    local fake = FakeTransport.new()
    T.boot {transport = fake, config = {networks = {{
        id = 'test',
        server = {host = 'test.example', port = 6667},
        identity = {nick = 'me'},
        features = features,
    }}}}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 376 me :End of MOTD'
    return c
end

local function record(topic)
    local seen = {}
    T.require 'hub.runtime.bus'.on(HUB.current.bus, topic, 'test', function(ev)
        table.insert(seen, ev)
    end)
    return seen
end

local function lines_of(name)
    local lines = {}
    for line in io.lines(here .. '/fixtures/' .. name .. '.log') do
        if line ~= '' and line:sub(1, 1) ~= '#' then
            table.insert(lines, line)
        end
    end
    return lines
end

local covered = {}

for _, name in ipairs(fixtures) do
    T.case('replay ' .. name, function()
        local c = boot {'snotice'}
        local events = record 'snote'
        local expected = dofile(here .. '/fixtures/' .. name .. '.expected.lua')
        local lines = lines_of(name)
        T.eq(#lines, #expected, 'one expectation per line')

        for i, line in ipairs(lines) do
            local before = #events
            c:recv(line)
            local want = expected[i]
            if want then
                T.eq(#events, before + 1, 'event for line ' .. i)
                local got = events[#events]
                T.eq(got.net, 'test', 'network')
                T.ok(got.timestamp, 'timestamp')
                got.net, got.timestamp = nil, nil
                T.eq(got, want, 'line ' .. i .. ': ' .. line)
                covered[want.name] = true
            else
                T.eq(#events, before, 'no event for line ' .. i .. ': ' .. line)
            end
        end
    end)
end

T.case('fixtures cover every notice', function()
    local missing = {}
    for _, name in ipairs(required) do
        if not covered[name] then table.insert(missing, name) end
    end
    T.eq(missing, {}, 'notices without a fixture')
end)

T.case('per-name events, and nothing without the feature', function()
    local c = boot {'snotice'}
    local connects = record 'snote.connect'
    c:recv ':gold.example NOTICE * :*** Notice -- Client connecting: n (u@h.example) [192.0.2.1] {users} <*> [Real Name]'
    T.eq(#connects, 1, 'snote.connect')
    T.eq(connects[1].nick, 'n', 'parsed')

    -- a notice from a user is not a server notice
    c:recv ':n!u@h NOTICE * :*** Notice -- Client connecting: n (u@h.example) [192.0.2.1] {users} <*> [x]'
    T.eq(#connects, 1, 'ignored')

    c = boot {'chat'}
    local any = record 'snote'
    c:recv ':gold.example NOTICE * :*** Notice -- Client connecting: n (u@h.example) [192.0.2.1] {users} <*> [Real Name]'
    T.eq(any, {}, 'snotice disabled')
end)

-- Store semantics ====================================================

local function notice(c, server, text)
    c:recv(':' .. server .. ' NOTICE * :*** Notice -- ' .. text)
end

local function stores()
    return T.require 'hub.features.snotice.stores'.get 'test'
end

local function keys(om)
    local OrderedMap = T.require 'hub.lib.OrderedMap'
    local list = {}
    for _, k in OrderedMap.reveach(om) do table.insert(list, k) end
    return list
end

T.case('connections, nick changes and exits', function()
    local c = boot {'snotice'}
    T.require 'hub.features.snotice.ip_org'.set_impl(function(ip)
        if ip == '192.0.2.1' then return 'Example Org', 64496 end
    end)
    local OrderedMap = T.require 'hub.lib.OrderedMap'

    notice(c, 'a.example', 'Client connecting: Alice (~al@h.example) [192.0.2.1] {users} <acct> [Alice A]')
    notice(c, 'a.example', 'Nick change: From Alice to Alice_ [~al@h.example]')
    notice(c, 'a.example', 'FILTER: Alice_!~al@h.example [192.0.2.1]')
    notice(c, 'a.example', 'Client exiting: alice_ (~al@h.example) [Quit: bye] [192.0.2.1]')

    local S = stores()
    local user = OrderedMap.lookup(S.users, 'ALICE_')
    T.ok(user, 'found by folded nick after the rename')
    T.eq({user.nick, user.reason, user.filters, user.count}, {'Alice_', 'Quit: bye', 1, 1}, 'entry')
    T.eq({user.org, user.asn, user.account}, {'Example Org', 64496, 'acct'}, 'org and account')
    T.eq(user.mask, 'Alice_!~al@h.example#Alice A', 'mask follows the nick')

    local exit = OrderedMap.each(S.exits)()
    T.eq({exit.nick, exit.gecos, exit.reason, exit.org}, {'alice_', 'Alice A', 'Quit: bye', 'Example Org'}, 'exit')

    notice(c, 'a.example', 'Client connecting: Alice_ (~al@h.example) [192.0.2.1] {users} <*> [Alice A]')
    T.eq(OrderedMap.lookup(S.users, 'alice_').count, 2, 'reconnects counted')
    T.require 'hub.features.snotice.ip_org'.set_impl(nil)
end)

T.case('the life of a K-Line', function()
    local c = boot {'snotice'}
    notice(c, 'a.example', 'op!o@staff/op{op} added global 60 min. K-Line for [*@192.0.2.9] [spam]')
    notice(c, 'a.example', 'Disconnecting K-Lined user n1[~u@h1] (*@192.0.2.9)')
    notice(c, 'b.example', 'Rejecting K-Lined user n1[~u@h1] [192.0.2.9] (*@192.0.2.9)')
    notice(c, 'b.example', 'Rejecting K-Lined user n2[~u@h2] [192.0.2.9] (*@192.0.2.9)')

    local OrderedMap = T.require 'hub.lib.OrderedMap'
    local S = stores()
    local kline = OrderedMap.lookup(S.klines, 'kline *@192.0.2.9')
    T.eq({kline.oper, kline.duration, kline.reason, kline.kind}, {'op', 60, 'spam', 'kline'}, 'kline')
    T.eq(kline.nicks, {n1 = 2, n2 = 1}, 'hits by nick')

    -- every server reports the removal; one entry is enough
    notice(c, 'a.example', 'op!o@staff/op{op} has removed the global K-Line for: [*@192.0.2.9]')
    notice(c, 'b.example', 'op!o@staff/op{op} has removed the global K-Line for: [*@192.0.2.9]')
    T.eq(kline.kind, 'inactive', 'removed')
    T.eq(keys(S.klines), {'kline *@192.0.2.9', 'unkline *@192.0.2.9'}, 'one unkline entry')

    notice(c, 'a.example', 'op!o@staff/op{op} added global 60 min. K-Line for [*@192.0.2.8] [spam]')
    notice(c, 'a.example', 'Temporary K-line for [*@192.0.2.8] expired')
    T.eq(OrderedMap.lookup(S.klines, 'kline *@192.0.2.8').kind, 'inactive', 'expired')

    -- the same D-Line reported twice is kept once
    notice(c, 'a.example', 'op!o@staff/op{op} added global 60 min. D-Line for [198.51.100.0/24] [x]')
    notice(c, 'b.example', 'op!o@staff/op{op} added global 60 min. D-Line for [198.51.100.0/24] [x]')
    local n = 0
    for _, k in ipairs(keys(S.klines)) do
        if k == 'dline 198.51.100.0/24' then n = n + 1 end
    end
    T.eq(n, 1, 'one dline')
    T.eq(OrderedMap.size(S.klines), 4, 'entries')
end)

T.case('new channels, flooders and spambots group by nick', function()
    local c = boot {'snotice'}
    notice(c, 'a.example', 'm is creating new channel #one')
    notice(c, 'a.example', 'Possible Flooder m[~u@h] on a.example target: #one')
    notice(c, 'a.example', 'User m (~u@h) trying to join #two is a possible spambot')
    notice(c, 'a.example', 'z is creating new channel #three')

    local OrderedMap = T.require 'hub.lib.OrderedMap'
    local entries = {}
    for e in OrderedMap.reveach(stores().new_channels) do
        table.insert(entries, {e.nick, e.channels, e.flags})
    end
    T.eq(entries, {
        {'m', {'#one', '#two'}, {1 | 2, 4}},
        {'z', {'#three'}, {1}},
    }, 'entries')
end)

T.case('trackers sample once a second', function()
    local c = boot {'snotice'}
    for _ = 1, 3 do
        notice(c, 'a.example', 'Client connecting: n (u@h) [192.0.2.1] {users} <*> [g]')
    end
    notice(c, 'b.example', 'Client exiting: n (u@h) [Client Quit] [192.0.2.1]')
    HUB.current.routes['app.tick']()
    local S = stores()
    T.eq(S.trackers.conn.global.recent[1], 3, 'connections this second')
    T.eq(S.trackers.conn.detail['a.example'].recent[1], 3, 'by server')
    T.eq(S.trackers.exit.global.recent[1], 1, 'exits')
    HUB.current.routes['app.tick']()
    T.eq(S.trackers.conn.global.recent[2], 0, 'next second')
end)

T.case('watches mark entries and alert', function()
    local c = boot {'snotice'}
    local alerts = record 'notify.alert'
    table.insert(stores().watches, {pattern = 'badguy', active = true, hits = 0, color = 'yellow', beep = true})
    notice(c, 'a.example', 'Client connecting: BadGuy (u@h) [192.0.2.1] {users} <*> [g]')
    notice(c, 'a.example', 'Client connecting: fine (u@h) [192.0.2.1] {users} <*> [g]')
    local OrderedMap = T.require 'hub.lib.OrderedMap'
    T.eq(OrderedMap.lookup(stores().users, 'BadGuy').mark, 'yellow', 'marked')
    T.eq(stores().watches[1].hits, 1, 'hits')
    T.eq(#alerts, 1, 'one alert')
    T.eq({alerts[1].net, alerts[1].kind, alerts[1].beep}, {'test', 'watch', true}, 'alert')
end)

T.case('watches from configuration', function()
    local function config(watches)
        return {networks = {{
            id = 'test', server = {host = 'test.example', port = 6667},
            identity = {nick = 'me'}, features = {'snotice'}, watches = watches,
        }}}
    end
    local fake = FakeTransport.new()
    T.boot {transport = fake, config = config {{pattern = 'evil', color = 'magenta', beep = true}}}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 376 me :End of MOTD'

    -- one added by hand stays across reloads
    table.insert(stores().watches, {pattern = 'manual', active = true, hits = 0})
    notice(c, 'a.example', 'Client connecting: EvilBot (u@h) [192.0.2.1] {users} <*> [g]')
    local w = stores().watches[1]
    T.eq({w.pattern, w.color, w.beep, w.hits, w.from_config}, {'evil', 'magenta', true, 1, true}, 'configured watch hit')

    T.ok(T.reload {config = config {{pattern = 'evil', color = 'red'}, {pattern = 'other'}}}, 'reload')
    local patterns = {}
    for _, watch in ipairs(stores().watches) do
        table.insert(patterns, watch.pattern .. ':' .. watch.hits)
    end
    T.eq(patterns, {'evil:1', 'other:0', 'manual:0'}, 'configured first, hits kept, manual kept')
    T.eq(stores().watches[1].color, 'red', 'updated')

    T.ok(T.reload {config = config {}}, 'reload')
    T.eq(#stores().watches, 1, 'only the manual one is left')
end)

T.case('network trackers count connections by range', function()
    local c = boot {'snotice'}
    local nettrack = T.require 'hub.features.snotice.nettrack'
    local trackers = stores().net_trackers
    nettrack.add(trackers, 'docs', '192.0.2.0/25')
    nettrack.add(trackers, 'docs', '2001:db8::/32')
    nettrack.set(trackers, '192.0.2.0/25', 10)

    notice(c, 'a.example', 'Client connecting: n (u@h) [192.0.2.5] {users} <*> [g]')
    notice(c, 'a.example', 'Client connecting: n (u@h) [192.0.2.200] {users} <*> [g]')
    notice(c, 'a.example', 'Client connecting: n (u@h) [2001:db8::1] {users} <*> [g]')
    notice(c, 'a.example', 'Client exiting: n (u@h) [Client Quit] [192.0.2.6]')
    T.eq(trackers.docs['192.0.2.0/25'].count, 10, 'in, in, out')
    T.eq(trackers.docs['2001:db8::/32'].count, 1, 'ipv6')
    T.eq(nettrack.total(trackers.docs), 11, 'total')
    T.raises('bad address range', nettrack.new_range, 'nonsense')
end)

T.case('the wanted nick is reclaimed when its holder leaves', function()
    local c = boot {'snotice'}
    HUB.state.nets.test.irc.recover_nick = 'ME'
    c:take()
    notice(c, 'a.example', 'Client exiting: Me (u@h) [Client Quit] [192.0.2.1]')
    T.eq(c:take(), {'NICK me'}, 'reclaimed')
    notice(c, 'a.example', 'Nick change: From ME to other [u@h]')
    T.eq(c:take(), {'NICK me'}, 'reclaimed after a rename')
end)

T.case('the live replay builds consistent stores', function()
    local c = boot {'snotice'}
    for _, line in ipairs(lines_of 'snotes-live') do
        c:recv(line)
    end
    local OrderedMap = T.require 'hub.lib.OrderedMap'
    local S = stores()
    local expected = dofile(here .. '/fixtures/snotes-live.expected.lua')
    local count = {}
    for _, ev in ipairs(expected) do
        if ev then count[ev.name] = (count[ev.name] or 0) + 1 end
    end
    T.eq(S.users.n, count.connect, 'every connection recorded')
    T.eq(S.exits.n, count.disconnect, 'every exit recorded')
    T.eq(S.new_channels.n > 0, true, 'channel creations')

    local hits, klines = 0, 0
    for entry in OrderedMap.each(S.klines) do
        if entry.kind == 'kline' or entry.kind == 'inactive' then klines = klines + 1 end
        for _, n in pairs(entry.nicks or {}) do hits = hits + n end
    end
    T.eq(klines, count.kline, 'every K-Line recorded')
    T.ok(hits > 0, 'rejections matched to their K-Lines')
end)

T.run()
