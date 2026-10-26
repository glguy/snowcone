-- Ban staging and the Libera K-Line mask rules.
--
-- Run with:  snowcone script tests/hub/test-oper.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local FakeTransport = dofile(here .. '/fake_transport.lua')
local path = require 'pl.path'

local function boot()
    local fake = FakeTransport.new()
    T.boot {transport = fake, config = {networks = {{
        id = 'test',
        server = {host = 'test.example', port = 6667},
        identity = {nick = 'me'},
        servers_file = path.abspath(here .. '/fixtures/servers.lua'),
    }}}}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 376 me :End of MOTD'
    c:take()
    return c, T.require 'hub.features.oper'
end

T.case('mask rules (the dashboard asserts)', function()
    boot()
    local masks = T.require 'hub.features.oper.masks'
    T.eq(masks('~0a000001', '10.0.0.1', '10.0.0.1'), '*@10.0.0.1', 'simple')
    T.eq(masks('user', '255.255.255.255', 'gateway/something/somethingelse'), '*@gateway/something/somethingelse', 'account gateway')
    T.eq(masks('user', '10.0.0.1', 'localhost.localdomain'), 'user@10.0.0.1', 'no cloak with rDNS')
    T.eq(masks('user', '10.0.0.1', '10.0.0.1'), 'user@10.0.0.1', 'no cloak no rDNS')
    T.eq(masks('~user', '10.0.0.1', 'localhost.localdomain'), '*@10.0.0.1', 'no identd')
    T.eq(masks('~user', '10.0.0.1', 'unaffiliated/spammer'), '*@10.0.0.1', 'cloak without identd')
    T.raises('Immune', masks, 'user', '127.0.0.1', 'freenode/bot/target')
    T.raises('unresolved session', masks, 'user', '255.255.255.255', 'gateway/web/stuff/session')
    T.eq(masks('~user', '2001:470:7857:c::6667', '2001:470:7857:c::6667'), '*@2001:470:7857:c::6667', 'ipv6')
    T.eq(masks('~user', '1.2.3.4', 'gateway/vpn/provider/user'), '*@gateway/vpn/provider/user', 'VPN account')
    T.eq(masks('~user', '1.2.3.4', 'gateway/vpn/provider/user/x-11111111'),
        '*@gateway/vpn/provider/user/x-11111111', 'VPN account with x- suffix')
    T.eq(masks('~user', '255.255.255.255', 'gateway/tor-sasl/user/x-12345'), '*@gateway/tor-sasl/user/x-12345', 'Tor')
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
    oper.prepare_kline('test', 'n', 'u', 'gateway/web/x/session', nil)
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

T.case('kline_nick looks up unknown users with WHO', function()
    local c = boot()
    T.require 'hub.ui.control'.init_state(HUB.state)
    local cmdline = T.require 'hub.ui.cmdline'
    cmdline.execute 'kline_nick Someone'
    T.eq(c:take(), {'WHO Someone %tuihn,696'}, 'WHO')
    c:recv ':srv 354 me 696 ~s 192.0.2.10 host.example Someone'
    T.eq(c:take(), {'TESTMASK *@192.0.2.10'}, 'staged from WHO')
end)

T.case('an empty reason list falls back to a default', function()
    local _, oper = boot()
    T.require 'hub.features.topology'.get('test').servers.kline_reasons = {}
    oper.cycle_reason 'test'
    T.eq(oper.reason_text 'test', 'You are banned.', 'default reason')
end)

T.case('durations', function()
    local _, oper = boot()
    T.eq(oper.parse_duration '1d', 1440, '1d')
    T.eq(oper.parse_duration '1w 2h', 10200, '1w 2h')
    T.eq(oper.parse_duration 'soon', nil, 'nonsense')
    T.eq(oper.pretty_duration(90), '1.5 h', 'pretty')
    T.require 'hub.ui.control'.init_state(HUB.state)
    T.require 'hub.ui.cmdline'.execute 'duration 2 d'
    T.eq(oper.get('test').settings.duration, '2d', '/duration')
end)

T.run()
