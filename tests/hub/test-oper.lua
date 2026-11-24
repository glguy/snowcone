-- Ban staging and the Libera K-Line mask rules.
--
-- Run with:  snowcone tests/hub/test-oper.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local FakeTransport = dofile(here .. '/fake_transport.lua')
local path = require 'pl.path'

local function boot(features, labeled, ircd)
    local fake = FakeTransport.new()
    T.boot {transport = fake, config = {networks = {{
        id = 'test',
        ircd = ircd,
        server = {host = 'test.example', port = 6667},
        identity = {nick = 'me'},
        servers_file = path.abspath(here .. '/fixtures/servers.toml'),
        features = features,
    }}}}
    local c = fake.last()
    c:con()
    if labeled then
        c:recv ':srv CAP * LS :batch labeled-response'
        c:recv ':srv CAP me ACK :batch labeled-response'
    else
        c:recv ':srv CAP * LS :'
    end
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 376 me :End of MOTD'
    c:take()
    return c, T.require 'hub.features.oper'
end

T.case('/oper logs in with a named credential, or the automatic ones', function()
    local fake = FakeTransport.new()
    T.boot {transport = fake, config = {networks = {{
        id = 'test',
        server = {host = 'test.example', port = 6667},
        identity = {nick = 'me'},
        features = {'snotice', 'oper'},
        oper = {credentials = {
            {mechanism = 'password', username = 'first', password = 'p1'},
            {name = 'other', mechanism = 'password', username = 'second', password = 'p2'},
        }},
    }}}}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 376 me :End of MOTD'
    c:take()

    T.command 'oper other'
    T.eq(c:take(), {'OPER second p2'}, 'by name')
    c:recv ':srv 464 me :Password incorrect'

    T.command 'oper'
    T.eq(c:take(), {'OPER first p1'}, 'without automatic, the first credential')
    c:recv ':srv 491 me :No appropriate operator blocks were found for your host'
    T.eq(T.log_lines 'oper', {'password mismatch', 'host mismatch'}, 'outcomes logged')
end)

T.case('a credential that fails goes on to the next, and to MODE', function()
    local fake = FakeTransport.new()
    T.boot {transport = fake, config = {networks = {{
        id = 'test',
        server = {host = 'test.example', port = 6667},
        identity = {nick = 'me'},
        oper = {automatic = {'a', 'b'}, credentials = {
            {name = 'a', mechanism = 'password', username = 'first', password = {file = '/nonexistent/oper.pass'}},
            {name = 'b', mechanism = 'password', username = 'second', password = 'p2'},
        }},
    }}}}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 376 me :End of MOTD'
    local sent = c:take()
    T.eq(sent[#sent], 'OPER second p2', 'b after a fails')
    T.ok(T.log_lines('oper')[1]:find '^a: ', T.log_lines('oper')[1])
    c:recv ':srv 464 me :Password incorrect'
    T.eq(c:take(), {'MODE me'}, 'then MODE')
end)

T.case('/oper works on a network without the oper feature', function()
    local fake = FakeTransport.new()
    T.boot {transport = fake, config = {networks = {{
        id = 'test',
        server = {host = 'test.example', port = 6667},
        identity = {nick = 'me'},
        features = {'chat'},
        oper = {credentials = {{mechanism = 'password', username = 'o', password = 'p'}}},
    }}}}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 376 me :End of MOTD'
    c:take()
    T.command 'oper'
    local sent = c:take()
    T.eq(sent[#sent], 'OPER o p', 'sent')
end)

T.case('K-Line mask rules', function()
    boot()
    local masks = T.require 'hub.features.oper.masks'
    T.eq(masks('~0a000001', '10.0.0.1', '10.0.0.1'), '*@10.0.0.1', 'simple')
    T.eq(masks('user', '255.255.255.255', 'gateway/something/somethingelse'), '*@gateway/something/somethingelse', 'account gateway')
    T.eq(masks('user', '10.0.0.1', 'localhost.localdomain'), 'user@10.0.0.1', 'no cloak with rDNS')
    T.eq(masks('user', '10.0.0.1', '10.0.0.1'), 'user@10.0.0.1', 'no cloak no rDNS')
    T.eq(masks('~user', '10.0.0.1', 'localhost.localdomain'), '*@10.0.0.1', 'no identd')
    T.eq(masks('~user', '10.0.0.1', 'unaffiliated/spammer'), '*@10.0.0.1', 'cloak without identd')
    T.raises('Immune', masks, 'user', '127.0.0.1', 'freenode/bot/target')
    T.eq(masks('~user', '2001:470:7857:c::6667', '2001:470:7857:c::6667'), '*@2001:470:7857:c::6667', 'ipv6')
    T.eq(masks('~user', '1.2.3.4', 'gateway/vpn/provider/user'), '*@gateway/vpn/provider/user', 'VPN account')
    T.eq(masks('user', '255.255.255.255', 'gateway/tor-sasl/user'), '*@gateway/tor-sasl/user', 'Tor, ident ignored')
    T.raises('Spoofed', masks, 'user', '255.255.255.255', 'staff/host')
    T.eq(masks('~user', '10.0.0.1', 'h', true), '~user@10.0.0.1', 'trusting the username')
end)

T.case('stage, count and send a K-Line', function()
    local c, oper = boot()
    c:recv ':srv NOTICE * :*** Notice -- Client connecting: bad (~b@host.example) [192.0.2.5] {users} <acct9> [Bad]'
    local stores = T.require 'hub.features.snotice.stores'
    local entry = T.require 'hub.lib.OrderedMap'.lookup(stores.get('test').users, 'bad')
    oper.entry_to_kline('test', entry)
    T.eq(c:take(), {'TESTMASK *@192.0.2.5'}, 'TESTMASK')
    T.eq(oper.get('test').staged.mask, '*@192.0.2.5', 'staged')

    c:recv ':srv 727 me 2 3 *!*@192.0.2.5 * :Local/remote clients match'
    T.eq(oper.get('test').staged.count, 5, 'counted')

    oper.cycle_reason('test')
    oper.cycle_tag('test')
    T.eq(oper.reason_text('test'), 'Abuse|ticket %tagged', 'reason with a tag after |')
    oper.cycle_duration('test')
    T.eq(oper.get('test').settings.duration, '3d', 'duration cycled')

    oper.get('test').settings.add_freeze = true
    T.eq(oper.freeze_account('test'), 'acct9', 'freeze the account')
    oper.commit('test')
    T.eq(c:take(), {'KLINE 4320 *@192.0.2.5 :Abuse|ticket %tagged', 'NS FREEZE acct9 ON %tagged'}, 'sent')
    T.eq(oper.get('test').staged, nil, 'done')
    T.raises('nothing ready', oper.commit, 'test')
end)

T.case('a bad mask stages nothing', function()
    local c, oper = boot()
    oper.prepare_kline('test', 'n', 'u', 'host.example', nil)
    T.eq(oper.get('test').staged, nil, 'not staged')
    T.eq(c:take(), {}, 'nothing sent')
end)

T.case('unkline finds the mask with TESTKLINE', function()
    local c, oper = boot()
    oper.entry_to_unkline('test', {nick = 'n', user = '~u', ip = '192.0.2.7'})
    T.eq(c:take(), {'TESTKLINE ~u@192.0.2.7'}, 'probe')
    T.eq(oper.ready('test'), false, 'not ready yet')
    c:recv ':srv 725 me k 60 *@192.0.2.7 :reason'
    T.eq(oper.get('test').staged.mask, '*@192.0.2.7', 'found')
    oper.commit('test')
    T.eq(c:take(), {'UNKLINE *@192.0.2.7'}, 'sent')

    oper.entry_to_unkline('test', {nick = 'n', user = '~u', ip = '192.0.2.8'})
    c:take()
    c:recv ':srv 726 me ~u@192.0.2.8 :No matches'
    T.eq(oper.get('test').staged, nil, 'nothing to remove')

    oper.stage_undline('test', '198.51.100.0/24')
    oper.commit('test')
    T.eq(c:take(), {'UNDLINE 198.51.100.0/24'}, 'undline')
end)

T.case('trusting the username restages', function()
    local c, oper = boot()
    oper.prepare_kline('test', 'n', '~u', 'h.example', '192.0.2.9')
    c:take()
    oper.toggle_trust('test')
    T.eq(oper.get('test').staged.mask, '~u@192.0.2.9', 'restaged')
    T.eq(c:take(), {'TESTMASK ~u@192.0.2.9'}, 'counted again')
end)

T.case('a labeled TESTMASK counts only its own staging', function()
    local c, oper = boot(nil, true)
    oper.prepare_kline('test', 'n', '~u', 'h.example', '192.0.2.9')
    T.eq(c:take(), {'@label=sc1 TESTMASK *@192.0.2.9'}, 'labeled')
    oper.toggle_trust('test')
    T.eq(c:take(), {'@label=sc2 TESTMASK ~u@192.0.2.9'}, 'restaged')

    c:recv '@label=sc1 :srv 727 me 7 0 *!*@192.0.2.9 * :Local/remote clients match'
    T.eq(oper.get('test').staged.count, nil, 'the old staging is not counted')
    c:recv '@label=sc2 :srv 727 me 1 1 *!~u@192.0.2.9 * :Local/remote clients match'
    T.eq(oper.get('test').staged.count, 2, 'counted')

    oper.prepare_kline('test', 'n', '~u', 'h.example', '192.0.2.11')
    c:recv '@label=sc3 :srv 723 me testmask :Insufficient oper privs'
    T.eq(oper.get('test').staged.count, nil, 'no count')
    T.eq(T.log_lines 'kline', {'no TESTMASK count for ~u@192.0.2.11'}, 'said so')
    T.eq(next(HUB.tasks), nil, 'no tasks left')
end)

T.case('an unkline by mask checks that a K-Line matches', function()
    local c, oper = boot(nil, true)
    oper.stage_unkline('test', '*@192.0.2.12')
    T.eq(c:take(), {'@label=sc1 TESTLINE *@192.0.2.12'}, 'TESTLINE')
    T.eq(oper.ready('test'), true, 'ready meanwhile')
    c:recv '@label=sc1 :srv 725 me k 60 *@192.0.2.12 :reason'
    T.eq(oper.get('test').staged.mask, '*@192.0.2.12', 'still staged')

    oper.stage_unkline('test', '*@192.0.2.13')
    c:recv '@label=sc2 :srv 726 me *@192.0.2.13 :No matches'
    T.eq(oper.get('test').staged, nil, 'nothing to remove')
    T.eq(T.log_lines 'unkline', {'no K-Line matches *@192.0.2.13'}, 'said so')
end)

T.case('unkline lookups read what Solanum answers', function()
    local c, oper = boot(nil, true)
    oper.entry_to_unkline('test', {nick = 'n', user = '~u', ip = '192.0.2.20'})
    c:recv '@label=sc1 :srv BATCH +b labeled-response'
    c:recv '@batch=b :srv 725 me ! 0 192.0.2.20 :Throttled'
    c:recv '@batch=b :srv 725 me K 0 *@192.0.2.20 :reason'
    c:recv ':srv BATCH -b'
    T.eq(oper.get('test').staged.mask, '*@192.0.2.20', 'a permanent K-Line, after a throttle line')

    oper.entry_to_unkline('test', {nick = 'n', user = '~u', ip = '192.0.2.21'})
    c:recv '@label=sc2 :srv 725 me d 60 192.0.2.21 :dlined'
    T.eq(oper.get('test').staged, nil, 'a D-Line is not a K-Line')
    T.eq(T.log_lines 'unkline', {'no K-Line found for ~u@192.0.2.21'}, 'said so')

    oper.stage_unkline('test', '*@192.0.2.22')
    c:recv '@label=sc3 :srv 215 me I name <NULL> *@* 0 users :'
    T.eq(oper.get('test').staged, nil, 'only an auth block matches')

    oper.stage_unkline('test', '*@192.0.2.23')
    c:recv '@label=sc4 :srv BATCH +b labeled-response'
    c:recv '@batch=b :srv 725 me ! 0 192.0.2.23 :Throttled'
    c:recv '@batch=b :srv 726 me *@192.0.2.23 :No matches'
    c:recv ':srv BATCH -b'
    T.eq(oper.get('test').staged, nil, 'a throttle line is not a match')
end)

T.case('on OFTC hybrid, TESTMASK counts and TESTLINE finds K-Lines', function()
    local c, oper = boot(nil, true, 'oftc-hybrid')
    c:recv ':srv NOTICE me :Client connecting: bad (~b@host.example) [192.0.2.5] {users} [Bad]'
    local stores = T.require 'hub.features.snotice.stores'
    local entry = T.require 'hub.lib.OrderedMap'.lookup(stores.get('test').users, 'bad')
    oper.entry_to_kline('test', entry)
    T.eq(c:take(), {'@label=sc1 TESTMASK *@192.0.2.5'}, 'TESTMASK')
    c:recv '@label=sc1 :srv 724 me *@192.0.2.5 2 3 :Local/remote clients match.'
    T.eq(oper.get('test').staged.count, 5, 'counted')
    oper.get('test').settings.add_freeze = true
    T.eq(oper.freeze_account('test'), nil, 'no account to freeze')

    oper.entry_to_unkline('test', {nick = 'n', user = '~u', ip = '192.0.2.20'})
    T.eq(c:take(), {'@label=sc2 TESTLINE ~u@192.0.2.20'}, 'TESTLINE, not TESTKLINE')
    c:recv '@label=sc2 :srv BATCH +b labeled-response'
    c:recv '@batch=b :srv 725 me D 0 192.0.2.20 :dlined | '
    c:recv '@batch=b :srv 725 me k 60 *@192.0.2.20 :reason | why'
    c:recv '@batch=b :srv 725 me I 0 *@* :users | '
    c:recv ':srv BATCH -b'
    T.eq(oper.get('test').staged.mask, '*@192.0.2.20', 'the K-Line after a D-Line')

    oper.stage_unkline('test', '*@192.0.2.22')
    c:recv '@label=sc3 :srv 725 me I 0 *@* :users | '
    T.eq(oper.get('test').staged, nil, 'only an auth block matches')
    T.eq(T.log_lines 'unkline', {'no K-Line matches *@192.0.2.22'}, 'said so')

    oper.prepare_kline('test', 'n', '~u', 'h.example', '192.0.2.9')
    c:take()
    oper.trace('test')
    T.eq(c:take(), {}, 'no MASKTRACE')
    T.eq(T.log_lines 'oper', {'OFTC hybrid has no MASKTRACE'}, 'said so')
end)

T.case('on OFTC hybrid, unlabeled TESTLINE ends at the auth block', function()
    local c, oper = boot(nil, false, 'oftc-hybrid')
    oper.entry_to_unkline('test', {nick = 'n', user = '~u', ip = '192.0.2.30'})
    T.eq(c:take(), {'TESTLINE ~u@192.0.2.30'}, 'TESTLINE')
    c:recv ':srv 725 me D 0 192.0.2.30 :dlined | '
    c:recv ':srv 725 me I 0 *@* :users | '
    T.eq(oper.get('test').staged, nil, 'no K-Line, at once')
    T.eq(T.log_lines 'unkline', {'no K-Line found for ~u@192.0.2.30'}, 'said so')
    T.eq(next(HUB.tasks), nil, 'finished')

    -- a D-Line is not the K-Line an unkline checks for
    oper.stage_unkline('test', '*@192.0.2.31')
    c:take()
    c:recv ':srv 725 me D 0 192.0.2.31 :dlined | '
    T.ok(oper.get('test').staged, 'still checking')
    c:recv ':srv 725 me I 0 *@* :users | '
    T.eq(oper.get('test').staged, nil, 'no K-Line matches')
end)

T.case('on OFTC hybrid, kline looks up with WHOIS', function()
    local c = boot(nil, false, 'oftc-hybrid')
    T.command 'kline Someone'
    T.eq(c:take(), {'WHOIS Someone'}, 'WHOIS, not WHOX')
    c:recv ':srv 311 me Someone ~s host.example * :Real'
    c:recv ':srv 338 me Someone 192.0.2.10 :actually using host'
    c:recv ':srv 318 me Someone :End of /WHOIS list.'
    T.eq(c:take(), {'TESTMASK *@192.0.2.10'}, 'staged from WHOIS')
end)

T.case('staging without a connection logs instead of raising', function()
    local c, oper = boot()
    c:finish 'reset'
    oper.prepare_kline('test', 'n', '~u', 'h.example', '192.0.2.14')
    T.eq(oper.get('test').staged.mask, '*@192.0.2.14', 'staged')
    T.eq(T.log_lines 'oper', {'network not connected: test'}, 'logged')
    oper.entry_to_unkline('test', {nick = 'n', user = '~u', ip = '192.0.2.15'})
    T.eq(oper.get('test').staged, nil, 'an unkline without its mask is dropped')
end)

T.case('kline looks up unknown users with WHO', function()
    local c = boot()
    T.command 'kline Someone'
    T.eq(c:take(), {'WHO Someone %tuihn,696'}, 'WHO')
    c:recv ':srv 354 me 696 ~s 192.0.2.10 host.example Someone'
    T.eq(c:take(), {'TESTMASK *@192.0.2.10'}, 'staged from WHO')
end)

T.case('kline stages a mask as typed and counts it', function()
    local c, oper = boot()
    T.command 'kline *@192.0.2.0/24'
    T.eq(c:take(), {'TESTMASK *@192.0.2.0/24'}, 'counted')
    c:recv ':srv 727 me 3 0 *!*@192.0.2.0/24 * :Local/remote clients match'
    local staged = oper.get('test').staged
    T.eq({staged.action, staged.mask, staged.nick, staged.count}, {'kline', '*@192.0.2.0/24', nil, 3}, 'staged')
    T.eq(oper.freeze_account('test'), nil, 'no user, no FREEZE')

    oper.commit('test')
    local sent = c:take()
    T.ok(sent[1]:find('^KLINE %d+ %*@192%.0%.2%.0/24 :'), sent[1])

    for _, bad in ipairs {'nick!u@h', 'u@h@h', '@h', 'u@'} do
        T.command('kline ' .. bad)
        T.eq(oper.get('test').staged, nil, 'refused: ' .. bad)
    end
    T.eq(c:take(), {}, 'nothing sent for those')
end)

T.case('kline without a connection says so', function()
    local c = boot()
    c:finish 'reset'
    T.command 'kline Someone'
    local found
    for _, line in ipairs(T.log_lines()) do
        T.ok(not line:find 'attempt to index', 'no crash: ' .. line)
        found = found or line:find 'network not connected' ~= nil
    end
    T.ok(found, 'not connected reported')
end)

T.case('the servers file reaches oper without the topology feature', function()
    local _, oper = boot {'oper', 'snotice'}
    T.eq(oper.reasons('test')[2].name, 'abuse', 'reasons from the file')
end)

T.case('an empty reason list falls back to a default', function()
    local _, oper = boot()
    T.require 'hub.features.common'.servers('test').kline_reasons = {}
    oper.cycle_reason 'test'
    T.eq(oper.reason_text 'test', 'You are banned.', 'default reason')
end)

T.case('an unkline lookup cut off by the connection is dropped, and says so', function()
    local c, oper = boot()
    oper.entry_to_unkline('test', {nick = 'n', user = '~u', ip = '192.0.2.5'})
    T.ok(oper.get('test').staged, 'staged while looking up')
    c:finish 'reset'
    T.eq(oper.get('test').staged, nil, 'dropped')
    local lines = T.log_lines 'unkline'
    T.ok(lines[#lines]:find('ended with the connection', 1, true), lines[#lines])
end)

T.case('durations', function()
    local _, oper = boot()
    T.eq(oper.parse_duration '1d', 1440, '1d')
    T.eq(oper.parse_duration '1w 2h', 10200, '1w 2h')
    T.eq(oper.parse_duration 'soon', nil, 'nonsense')
    T.eq(oper.parse_duration '99999999999999999999d', nil, 'too large')
    T.eq(oper.parse_duration '9999999999999999Y', nil, 'past a hundred years')
    T.eq(oper.parse_duration '-1d 2d', nil, 'no negatives')
    T.eq(oper.pretty_duration(90), '1.5 h', 'pretty')
    T.command 'duration 2 d'
    T.eq(oper.get('test').settings.duration, '2d', '/duration')
end)

T.case('STATS gathers its replies until its letter ends, and keeps the errors the end follows', function()
    local c = boot({'chat', 'snotice', 'oper'})
    local events = {}
    T.require 'hub.runtime.bus'.on(HUB.current.bus, 'query.listing', 'test', function(ev) table.insert(events, ev) end)
    local function last(category) local l = T.log_lines(category) return l[#l] end

    T.command 'stats k'
    T.eq(c:take(), {'STATS k'}, 'sent')
    c:recv ':srv 216 me k bad.example * ~u :spam|by alice'
    c:recv ':srv 216 me k worse.example * * :flood'
    c:recv ':srv 219 me k :End of /STATS report'
    T.eq(#events, 1, 'emitted')
    local l = events[1].listing
    T.eq({l.kind, l.command, #l.messages, #l.errors}, {'stats', 'STATS k', 2, 0}, 'its replies')
    T.eq(T.log_lines 'stats', {'STATS k: 2 replies'}, 'one line')

    -- refused: the end follows the error
    T.command 'stats z'
    c:take()
    c:recv ':srv 481 me :Permission Denied - You\'re not an IRC operator'
    c:recv ':srv 219 me z :End of /STATS report'
    T.eq({#events[2].listing.messages, #events[2].listing.errors}, {0, 1}, 'the error kept')
    T.eq(last 'stats', 'STATS z: 0 replies, refused', 'said so')

    -- disabled, and the end follows
    T.command 'stats e'
    c:take()
    c:recv ':srv 517 me STATS e :This command has been administratively disabled'
    c:recv ':srv 219 me e :End of /STATS report'
    T.eq(#events[3].listing.errors, 1, 'disabled is kept')

    -- another server's, which isn't there
    T.command 'stats u far.example'
    T.eq(c:take(), {'STATS u far.example'}, 'to a server')
    c:recv ':srv 402 me other.example :No such server'
    c:recv ':srv 402 me far.example :No such server'
    T.eq(last 'stats', 'STATS u far.example: No such server', 'only its own error fails it')
    T.eq(#events, 3, 'and opens nothing')

    -- two at once without labels: the rows before another's end are its own
    T.command 'stats K'
    T.command 'stats o'
    c:take()
    c:recv ':srv 216 me K a.example * * :a'
    c:recv ':srv 219 me K :End of /STATS report'
    c:recv ':srv 243 me O *@* * alice admin -1'
    c:recv ':srv 219 me o :End of /STATS report'
    T.eq({#events[4].listing.messages, #events[5].listing.messages}, {1, 1}, 'each its own')
    T.eq(events[5].listing.messages[1].command, 243, 'the O-line')

    -- the same letter twice: each end goes to the first waiting
    T.command 'stats q'
    T.command 'stats q'
    c:take()
    c:recv ':srv 217 me q 1 first :x'
    c:recv ':srv 219 me q :End of /STATS report'
    c:recv ':srv 217 me q 1 second :x'
    c:recv ':srv 219 me q :End of /STATS report'
    T.eq({events[6].listing.messages[1][4], events[7].listing.messages[1][4]}, {'first', 'second'},
        'in the order sent')

    -- a server's answer is told from ours by its source, whichever comes first
    T.command 'stats k far.example'
    T.command 'stats k'
    c:take()
    c:recv ':srv 216 me k near.example * * :ours'
    c:recv ':srv 219 me k :End of /STATS report'
    c:recv ':far.example 216 me k remote.example * * :theirs'
    c:recv ':far.example 219 me k :End of /STATS report'
    T.eq({events[8].listing.command, events[8].listing.messages[1][3]}, {'STATS k', 'near.example'}, 'ours first')
    T.eq({events[9].listing.command, events[9].listing.messages[1][3]}, {'STATS k far.example', 'remote.example'},
        "then the server's")
    T.eq(next(HUB.tasks), nil, 'finished')

    T.command 'stats kk'
    T.eq(c:take(), {}, 'a word is no letter')
    T.ok(T.log_lines 'error'[1]:find 'one ASCII character', 'and says why')
    T.command 'stats é'
    T.eq(c:take(), {}, 'nor is a letter past ASCII, as the server names a byte')
end)

T.case('listings sent before and after a reload each get their own reply', function()
    local c = boot {}
    local events = {}
    local function listen()
        T.require 'hub.runtime.bus'.on(HUB.current.bus, 'query.listing', 'test', function(ev)
            table.insert(events, ev.listing)
        end)
    end
    T.command 'stats q'
    T.command 'trace a.example'
    T.command 'stats k far.example'
    T.reload()
    listen()
    T.command 'stats q'
    T.command 'trace b.example'
    T.command 'stats k'
    c:take()
    c:recv ':srv 217 me q 1 first :x'
    c:recv ':srv 219 me q :End of /STATS report'
    c:recv ':srv 217 me q 1 second :x'
    c:recv ':srv 219 me q :End of /STATS report'
    c:recv ':srv 262 me b.example :End of TRACE'
    c:recv ':srv 262 me a.example :End of TRACE'
    c:recv ':srv 219 me k :End of /STATS report'
    c:recv ':far.example 219 me k :End of /STATS report'
    local commands = {}
    for i, l in ipairs(events) do commands[i] = l.command end
    T.eq(commands, {'STATS q', 'STATS q', 'TRACE b.example', 'TRACE a.example', 'STATS k', 'STATS k far.example'},
        'each ended by its own')
    T.eq({events[1].messages[1][4], events[2].messages[1][4]}, {'first', 'second'}, 'in the order sent')
    T.eq(next(HUB.tasks), nil, 'finished')
end)

T.case('queries and our modes need no feature', function()
    local c = boot {}
    for _, line in ipairs {'whois bob', 'wii bob', 'who #a', 'whowas bob', 'stats k', 'trace', 'etrace',
        'masktrace *@h.example', 'umode +i'}
    do
        T.command(line)
    end
    T.eq(c:take(), {'WHOIS bob', 'WHOIS bob bob', 'WHO #a', 'WHOWAS bob', 'STATS k', 'TRACE', 'ETRACE',
        'MASKTRACE *@h.example', 'MODE me +i'}, 'sent')
    T.eq(T.log_lines 'error', {}, 'none refused')
end)

T.case('on OFTC hybrid, a STATS refused for load ends there', function()
    local c = boot({'chat', 'snotice', 'oper'}, false, 'oftc-hybrid')
    T.command 'stats k'
    c:take()
    c:recv ':srv 263 me STATS :Server load is temporarily too heavy. Please wait a while and try again.'
    T.eq(T.log_lines 'stats', {'STATS k: Server load is temporarily too heavy. Please wait a while and try again.'},
        'failed')
    T.eq(next(HUB.tasks), nil, 'finished')
end)

T.case('TRACE, ETRACE and MASKTRACE end at RPL_ENDOFTRACE, each its own', function()
    local c, oper = boot({'chat', 'snotice', 'oper'})
    local events = {}
    T.require 'hub.runtime.bus'.on(HUB.current.bus, 'query.listing', 'test', function(ev) table.insert(events, ev) end)
    local function last(category) local l = T.log_lines(category) return l[#l] end

    T.command 'trace'
    T.eq(c:take(), {'TRACE'}, 'TRACE')
    c:recv ':srv 204 me Oper opers alice[a@192.0.2.1] (192.0.2.1) 5 0'
    c:recv ':srv 205 me User users bob[b@192.0.2.2] (192.0.2.2) 9 60'
    c:recv ':srv 209 me Class users 1'
    c:recv ':srv 262 me srv.example :End of TRACE'
    T.eq(#events[1].listing.messages, 3, 'every row')

    -- no such target: no end follows
    T.command 'trace nowhere'
    c:take()
    c:recv ':srv 402 me nowhere :No such server'
    T.eq(last 'trace', 'TRACE nowhere: No such server', 'failed')

    -- an oper command's refusal isn't TRACE's
    T.command 'trace'
    c:take()
    c:recv ':srv 481 me :Permission Denied'
    c:recv ':srv 262 me srv.example :End of TRACE'
    T.eq(#events, 2, 'still ended')

    -- two traces at once: each end goes to the first waiting
    T.command 'trace'
    T.command 'etrace'
    T.eq(c:take(), {'TRACE', 'ETRACE'}, 'both sent')
    c:recv ':srv 205 me User users bob[b@192.0.2.2] (192.0.2.2) 9 60'
    c:recv ':srv 262 me srv.example :End of TRACE'
    c:recv ':srv 709 me User users bob b h.example 192.0.2.2 :Bob'
    c:recv ':srv 262 me srv.example :End of TRACE'
    T.eq({events[3].listing.kind, events[3].listing.messages[1].command}, {'trace', 205}, 'TRACE its own')
    T.eq({events[4].listing.kind, events[4].listing.messages[1].command}, {'etrace', 709}, 'ETRACE its own')

    T.command 'etrace -full'
    T.eq(c:take(), {'ETRACE -full'}, 'ETRACE')
    c:recv ':srv 708 me User users bob b h.example 192.0.2.2 cap-notify :Bob'
    c:recv ':srv 262 me srv.example :End of TRACE'
    T.eq(#events[5].listing.messages, 1, 'its row')

    -- anything but its options is a nick
    T.command 'etrace -ful'
    c:take()
    c:recv ':srv 401 me -ful :No such nick/channel'
    T.eq(last 'etrace', 'ETRACE -ful: No such nick/channel', 'no such nick')

    T.command 'masktrace *@h.example Bob*'
    T.eq(c:take(), {'MASKTRACE *@h.example Bob*'}, 'MASKTRACE with a realname')
    c:recv ':srv 709 me User leaf.example bob b h.example 192.0.2.2 :Bob'
    c:recv ':srv 262 me srv.example :End of TRACE'
    T.eq({#events[6].listing.messages, events[6].listing.relabel}, {1, {class = 'server'}}, 'the server in the class')

    local listing = T.require 'hub.features.queries.listing'
    T.eq({listing.masktrace_mask 'n!u@h', listing.masktrace_mask 'u@h!x', listing.masktrace_mask '*!@h',
        listing.masktrace_mask 'u@', listing.masktrace_mask 'nobody'}, {true, true, false, false, false},
        'masks as the server splits them')
    T.command 'masktrace nobody'
    T.eq(c:take(), {}, 'a mask MASKTRACE refuses sends nothing')
    T.ok(T.log_lines 'error'[1]:find('not a [nick!]user@host mask', 1, true), 'and says why')

    -- the staged K-Line's trace opens the table too
    oper.prepare_kline('test', 'n', '~u', 'h.example', '192.0.2.9')
    c:take()
    oper.trace('test')
    T.eq(c:take(), {'MASKTRACE *@192.0.2.9'}, 'the staged mask')
    c:recv ':srv 262 me srv.example :End of TRACE'
    T.eq(#events, 7, 'shown')
    for _, t in pairs(HUB.tasks) do T.ok(t.name ~= 'masktrace', 'finished') end
end)

T.case('CHANTRACE lists a channel like MASKTRACE, and fails on its channel errors', function()
    local c = boot({'chat', 'snotice', 'oper'})
    local events = {}
    T.require 'hub.runtime.bus'.on(HUB.current.bus, 'query.listing', 'test', function(ev) table.insert(events, ev) end)

    T.command 'chantrace #a'
    T.eq(c:take(), {'CHANTRACE #a'}, 'sent')
    c:recv ':srv 709 me User leaf.example bob b h.example 192.0.2.2 :Bob'
    c:recv ':srv 709 me Oper srv.example alice a h.example 192.0.2.1 :Alice'
    -- the end names our server, not the channel
    c:recv ':srv 262 me srv.example :End of TRACE'
    T.eq({events[1].listing.kind, #events[1].listing.messages, events[1].listing.relabel},
        {'chantrace', 2, {class = 'server'}}, 'every user, the server in the class')

    T.command 'chantrace !#b'
    T.eq(c:take(), {'CHANTRACE !#b'}, 'operspy')
    c:recv ':srv 403 me #b :No such channel'
    T.eq(T.log_lines 'chantrace', {'CHANTRACE #a: 2 replies', 'CHANTRACE !#b: No such channel'},
        'no such channel, named without the !')

    -- without operspy the ! stays in the name looked up
    T.command 'chantrace !#d'
    c:take()
    c:recv ':srv 403 me !#d :No such channel'
    T.eq(T.log_lines 'chantrace'[3], 'CHANTRACE !#d: No such channel', 'no such channel, named with the !')

    T.command 'chantrace #c'
    c:take()
    c:recv ':srv 442 me #c :You\'re not on that channel'
    T.eq(T.log_lines 'chantrace'[4], "CHANTRACE #c: You're not on that channel", 'not on it')
    T.eq(next(HUB.tasks), nil, 'finished')

    T.command 'chantrace bob'
    T.eq(c:take(), {}, 'a nick sends nothing')
    T.ok(T.log_lines 'error'[1]:find('not a channel', 1, true), 'and says why')
end)

T.case('the ban commands send their lines as the server reads them', function()
    local c = boot({'chat', 'snotice', 'oper'})
    for _, line in ipairs {
        'unkline *@192.0.2.1', 'unkline ~u@h.example ON leaf.*',
        'dline 192.0.2.0/24', 'dline 1d12h 2001:db8::/32 on leaf.* proxy | open proxy',
        'undline 192.0.2.0/24 ON leaf.*',
        'xline 1w *bot\\s* spam bots', 'xline *bot* ON',
        'unxline *bot* ON leaf.*',
        'resv 60 #spam no', 'unresv #spam',
        'wallops hello all', 'operwall hello opers',
    } do
        T.command(line)
    end
    T.eq(c:take(), {
        'UNKLINE *@192.0.2.1', 'UNKLINE ~u@h.example ON leaf.*',
        'DLINE 192.0.2.0/24', 'DLINE 1d12h 2001:db8::/32 ON leaf.* :proxy | open proxy',
        'UNDLINE 192.0.2.0/24 ON leaf.*',
        'XLINE 1w *bot\\s* :spam bots', 'XLINE *bot* ON',
        'UNXLINE *bot* ON leaf.*',
        'RESV 60 #spam no', 'UNRESV #spam',
        'WALLOPS :hello all', 'OPERWALL :hello opers',
    }, 'sent')
    T.eq(T.log_lines 'error', {}, 'none refused')

    -- what the server would refuse with only a notice
    for _, line in ipairs {
        'unkline nobody', 'dline 1d', 'dline host.example', 'dline 192.0.2.0/33', 'dline ::1',
        'undline 192.0.2.*', 'xline *bot*', 'resv 30 #x', 'unxline *bot* ON', 'unresv #a #b',
    } do
        T.command(line)
    end
    T.eq(c:take(), {}, 'nothing sent')
    T.eq(T.log_lines 'error', {
        'unkline: not a user@host or host: nobody',
        'dline: no target after the duration 1d',
        'dline: not an address[/prefix]: host.example',
        'dline: a prefix past the address: 192.0.2.0/33',
        'dline: an address can\'t start with ":": ::1',
        'undline: not an address[/prefix]: 192.0.2.*',
        'xline: XLINE needs a reason',
        'resv: RESV needs a reason',
        'unxline: no server after ON',
        'unresv: more than UNRESV takes: #b',
    }, 'each says why')

    local lines = T.require 'hub.features.oper.lines'
    T.eq({lines.solanum_duration '30', lines.solanum_duration '1d12h', lines.solanum_duration '2w3',
        lines.solanum_duration '1d12', lines.solanum_duration '1y', lines.solanum_duration '-5',
        lines.solanum_duration 'd'}, {true, true, true, true, false, false, false}, 'durations as valid_temp_time reads them')
end)

T.case('the ban commands send what can go, and refuse a ":" before the last parameter', function()
    local c = boot({'chat', 'snotice', 'oper'})
    for _, line in ipairs {
        'unkline ::1', 'unkline ::1 ON leaf.*', 'unkline u@::1 ON leaf.*',
        'undline ::1', 'undline 192.0.2.0/33', 'dline 192.0.2.1 ON', 'dline 192.0.2.1 ON leaf.*',
    } do
        T.command(line)
    end
    T.eq(c:take(), {
        'UNKLINE *@::1', 'UNKLINE *@::1 ON leaf.*', 'UNKLINE u@::1 ON leaf.*',
        'UNDLINE :::1', 'UNDLINE 192.0.2.0/33', 'DLINE 192.0.2.1 ON', 'DLINE 192.0.2.1 ON leaf.*',
    }, 'a host alone as *@host before ON; a prefix past the address is UNDLINE\'s to clamp; ON alone the reason')
    T.eq(T.log_lines 'error', {}, 'none refused')

    for _, line in ipairs {
        'undline ::1 ON leaf.*', 'xline :foo bar', 'resv :x r', 'dline 192.0.2.1 ON :s r', 'unresv #a ON :s x',
        'wallops', 'wallops  ',
    } do
        T.command(line)
    end
    T.eq(c:take(), {}, 'nothing sent')
    local errors = T.log_lines 'error'
    T.eq({table.unpack(errors, 1, 5)}, {
        'undline: ::1 can\'t start with ":" before the last parameter',
        'xline: :foo can\'t start with ":" before the last parameter',
        'resv: :x can\'t start with ":" before the last parameter',
        'dline: :s can\'t start with ":" before the last parameter',
        'unresv: more than UNRESV takes: x',
    }, 'each says why')
    T.eq(#errors, 7, 'and wallops needs its text')
    T.ok(errors[6]:find('wallops', 1, true) and errors[7]:find('wallops', 1, true), 'twice')

    local lines = T.require 'hub.features.oper.lines'
    local cases = {
        {'192.0.2.0/24', true, 'ip'}, {'192.0.2.0/33', true, 'error'}, {'192.0.2.0/33', false, 'ip'},
        {'192.0.2.0/24x', true, 'error'}, {'192.0.2.0/', true, 'host'}, {'192.0.2.0/x', false, 'host'},
        {'2001:db8::/128', true, 'ip'}, {'2001:db8::/129', true, 'error'}, {'192.0.2.*', true, 'host'},
        {'host.example', true, 'host'}, {'nodots', true, 'host'}, {'::1', true, 'ip'},
    }
    for _, case in ipairs(cases) do
        T.eq(lines.netmask(case[1], case[2]), case[3], case[1] .. (case[2] and ' strict' or ' lax'))
    end
end)

T.case('on OFTC hybrid a duration is minutes', function()
    local c = boot({'chat', 'snotice', 'oper'}, false, 'oftc-hybrid')
    T.command 'resv 60 #spam no'
    T.command 'resv 1d #spam no'
    T.eq(c:take(), {'RESV 60 #spam no', 'RESV 1d :#spam no'}, '1d is the target')
end)

T.case('CHANTRACE is not on OFTC hybrid', function()
    local c = boot({'chat', 'snotice', 'oper'}, false, 'oftc-hybrid')
    T.command 'chantrace #a'
    T.eq(c:take(), {}, 'nothing sent')
    T.ok(T.log_lines 'error'[1]:find('no CHANTRACE', 1, true), 'said so')
end)

T.case('KILL sends a nick and its reason', function()
    local c = boot({'chat', 'snotice', 'oper'})
    T.command 'kill bob spamming the network'
    T.command 'kill bob'
    T.eq(c:take(), {'KILL bob :spamming the network', 'KILL bob'}, 'sent')
end)

T.case('with labeled-response a listing takes its own reply', function()
    local c = boot({'chat', 'snotice', 'oper'}, true)
    local events = {}
    T.require 'hub.runtime.bus'.on(HUB.current.bus, 'query.listing', 'test', function(ev) table.insert(events, ev) end)
    T.command 'trace'
    local sent = c:take()[1]
    local label = sent:match '^@label=([^ ]+) TRACE$'
    T.ok(label, 'labeled')
    c:recv('@label=' .. label .. ' :srv BATCH +b labeled-response')
    c:recv '@batch=b :srv 205 me User users bob[b@192.0.2.2] (192.0.2.2) 9 60'
    c:recv '@batch=b :srv 262 me srv.example :End of TRACE'
    c:recv ':srv BATCH -b'
    T.eq(#events[1].listing.messages, 1, 'its rows')
    T.eq(next(HUB.tasks), nil, 'finished')
end)

T.run()
