-- Topology, operator sync and the servers file.
--
-- Run with:  snowcone tests/hub/test-topology.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local FakeTransport = dofile(here .. '/fake_transport.lua')

-- What the client sent from CON to the end of registration
local registration_sent

local function boot(extra)
    local fake = FakeTransport.new()
    local net = {
        id = 'test',
        server = {host = 'test.example', port = 6667},
        identity = {nick = 'me'},
        servers_file = require 'pl.path'.abspath(here .. '/fixtures/servers.lua'),
    }
    for k, v in pairs(extra or {}) do net[k] = v end
    T.boot {transport = fake, config = {networks = {net}}}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 376 me :End of MOTD'
    registration_sent = c:take()
    return c
end

local function topo()
    return T.require 'hub.features.topology'.get 'test'
end

local function snotice()
    return T.require 'hub.features.snotice.stores'.get 'test'
end

T.case('the servers file is loaded and seeds the notice stores', function()
    boot()
    local servers = T.require 'hub.features.common'.servers 'test'
    T.eq(servers.primary_hub, 'hub.example', 'loaded')
    T.eq(servers.kline_reasons[2][1], 'abuse', 'kline reasons')
    local S = snotice()
    T.eq(S.trackers.conn.events['alpha.example'], 0, 'known servers tracked from the start')
    T.ok(S.net_trackers.docs['192.0.2.0/24'], 'address ranges from the file')
end)

T.case('a servers file that cannot be read fails the reload', function()
    boot()
    local before = HUB.current
    local file = require 'pl.path'.abspath(here .. '/fixtures/servers.lua')
    for _, bad in ipairs {file .. '.missing', here .. '/test-topology.lua'} do
        local ok, err = T.reload {config = {networks = {{
            id = 'test', server = {host = 'test.example', port = 6667},
            identity = {nick = 'me'}, servers_file = bad,
        }}}}
        T.ok(not ok and tostring(err):find('networks.test.servers_file', 1, true), tostring(err))
        T.ok(HUB.current == before, 'the old generation stays')
    end
    T.eq(T.require 'hub.features.common'.servers('test').primary_hub, 'hub.example', 'and its servers')
end)

T.case('registration asks for the map and links', function()
    boot()
    local tablex = T.require 'pl.tablex'
    T.ok(tablex.find(registration_sent, 'MAP') and tablex.find(registration_sent, 'LINKS'), 'MAP and LINKS')
end)

T.case('operator status syncs ranges, and topology unless it just did', function()
    local c = boot()
    -- already opered through a bouncer: user modes include o, right away
    c:recv ':srv 221 me +io'
    local sent = c:take()
    table.sort(sent)
    T.eq(sent, {
        'TESTMASK *@192.0.2.0/24', 'TESTMASK *@198.51.100.56/29', 'TESTMASK *@2001:db8::/32',
        'TESTMASK *@2001:db8:f::/62', 'TESTMASK *@203.0.113.7',
    }, 'ranges only')
    c:recv ':srv 221 me +io'
    T.eq(c:take(), {}, 'once per connection')
end)

T.case('opering up later syncs topology again', function()
    local c = boot()
    T.require 'hub.features.topology'.get('test').synced_at = -1e9
    c:recv ":srv 381 me :You're now an IRC operator"
    local sent = c:take()
    local tablex = T.require 'pl.tablex'
    T.ok(tablex.find(sent, 'MAP') and tablex.find(sent, 'LINKS'), 'resynced')
end)

T.case('opering sets the snomask', function()
    local c = boot {snomask = '+cF'}
    c:recv ":srv 381 me :You're now an IRC operator"
    local sent = c:take()
    T.ok(T.require 'pl.tablex'.find(sent, 'MODE me +s +cF'), 'configured snomask')
end)

T.case('MAP, LINKS, VERSION and STATS u', function()
    local c = boot()
    c:recv ':srv 015 me :alpha.example[01A] ---- | Users:   100 (10%)'
    c:recv ':srv 015 me :beta.example[01B] ----- | Users:  2000 (90%)'
    c:recv ':srv 015 me :gamma.example[01C] ---- | Users:     5 (0%)'
    c:recv ':srv 017 me :End of /MAP'
    T.eq(topo().population, {['alpha.example'] = 100, ['beta.example'] = 2000, ['gamma.example'] = 5}, 'population')
    T.eq(snotice().trackers.exit.events['gamma.example'], 0, 'every mapped server gets a load row')

    -- notices move the population
    c:recv ':alpha.example NOTICE * :*** Notice -- Client connecting: n (u@h) [192.0.2.1] {users} <*> [g]'
    c:recv ':beta.example NOTICE * :*** Notice -- Client exiting: n (u@h) [Client Quit] [192.0.2.1]'
    T.eq(topo().population, {['alpha.example'] = 101, ['beta.example'] = 1999, ['gamma.example'] = 5},
        'moved by notices')
    T.eq(snotice().net_trackers.docs['192.0.2.0/24'].count, 0, 'in and out of the range')

    c:recv ':srv 364 me alpha.example hub.example :1 Alpha'
    c:recv ':srv 364 me beta.example alpha.example :2 Beta'
    c:recv ':srv 364 me hub.example hub.example :0 Hub'
    c:recv ':srv 365 me * :End of /LINKS list.'
    T.eq(topo().upstream, {
        ['hub.example'] = 'hub.example',
        ['alpha.example'] = 'hub.example',
        ['beta.example'] = 'alpha.example',
    }, 'upstream towards the primary hub')

    c:recv ':alpha.example 351 me solanum-1.0(20260101-abc) alpha.example :eHIKMpSZ6'
    T.eq(topo().versions['alpha.example'], '20260101-abc', 'version')
    c:recv ':beta.example 242 me :Server Up 2 days, 03:04:05'
    T.ok(topo().uptimes['beta.example']:match '^%d+%-%d+%-%d+ %d+:%d+:%d+$', 'startup time')
end)

T.case('netsplit and netjoin resync', function()
    local c = boot()
    topo().versions['beta.example'] = 'old'
    topo().uptimes['beta.example'] = 'old'
    c:recv ':alpha.example NOTICE * :*** Notice -- Netsplit hub.example <-> beta.example (00H 01B) (Ping timeout: 120 seconds)'
    T.eq(topo().uptimes['beta.example'], nil, 'uptime forgotten')
    local sent = c:take()
    table.sort(sent)
    T.eq(sent, {
        'LINKS', 'MAP', 'TESTMASK *@192.0.2.0/24', 'TESTMASK *@198.51.100.56/29',
        'TESTMASK *@2001:db8::/32', 'TESTMASK *@2001:db8:f::/62', 'TESTMASK *@203.0.113.7',
    }, 'resync')

    c:recv ':alpha.example NOTICE * :*** Notice -- Netjoin hub.example <-> beta.example (00H 01B)'
    sent = c:take()
    T.ok(T.require 'pl.tablex'.find(sent, 'VERSION beta.example'), 'version asked again')
end)

T.case('TESTMASK replies set range counts', function()
    local c = boot()
    c:recv ':srv 727 me 5 7 *!*@192.0.2.0/24 * :Local/remote clients match'
    T.eq(snotice().net_trackers.docs['192.0.2.0/24'].count, 12, 'count')
end)

T.case('sheds and drains from notices', function()
    local c = boot()
    c:recv ':alpha.example NOTICE * :*** Notice -- Module drain [0x1] loaded at 0x2'
    c:recv ':alpha.example NOTICE * :*** Notice -- Module other [0x1] loaded at 0x2'
    c:recv ':beta.example NOTICE * :*** Notice -- o!o@staff/o{o} enabled user shedding (interval: 30 seconds, reason: x)'
    T.eq(topo().drains, {['alpha.example'] = true}, 'drain')
    T.eq(topo().sheds, {['beta.example'] = 30}, 'shed')
    c:recv ':alpha.example NOTICE * :*** Notice -- Module drain unloaded'
    c:recv ':beta.example NOTICE * :*** Notice -- o!o@staff/o{o} disabled user shedding'
    T.eq(topo().drains, {}, 'drain cleared')
    T.eq(topo().sheds, {}, 'shed cleared')
end)

T.case('/maintenance asks every server for sheds and drains', function()
    local c = boot()
    T.require 'hub.ui.control'.init_state(HUB.state)
    c:recv ':srv 015 me :alpha.example[01A] ---- | Users:    10 (10%)'
    c:recv ':srv 015 me :beta.example[01B] ----- | Users:    20 (20%)'
    c:recv ':srv 017 me :End of /MAP'
    topo().drains['beta.example'] = true
    c:take()
    T.require 'hub.ui.cmdline'.execute 'maintenance'
    T.eq(c:take(), {
        'STATS E alpha.example', 'MODLIST drain alpha.example',
        'STATS E beta.example', 'MODLIST drain beta.example',
    }, 'asked both')
    c:recv ':alpha.example 249 me E :user shedding event   12 seconds (frequency=60)'
    c:recv ':alpha.example 219 me E :End of /STATS report'
    c:recv ':alpha.example 702 me drain 0x1 extension'
    c:recv ':alpha.example 703 me :End of /MODLIST.'
    c:recv ':beta.example 219 me E :End of /STATS report'
    T.eq(topo().drains, {['alpha.example'] = true, ['beta.example'] = true}, 'beta not done yet')
    c:recv ':beta.example 703 me :End of /MODLIST.'
    T.eq(topo().sheds, {['alpha.example'] = 60}, 'sheds')
    T.eq(topo().drains, {['alpha.example'] = true}, 'drains')
    local lines = T.log_lines 'maintenance'
    T.eq(lines[#lines], 'Shedding: alpha.example; draining: alpha.example', 'summary')
    T.eq(next(HUB.tasks), nil, 'finished')
end)

T.case('a netjoin rechecks a flagged server', function()
    local c = boot()
    topo().drains['beta.example'] = true
    c:take()
    c:recv ':hub.example NOTICE * :*** Notice -- Netjoin hub.example <-> beta.example (00H 01B)'
    local sent = c:take()
    T.ok(table.concat(sent, '\n'):find('STATS E beta.example\nMODLIST drain beta.example', 1, true),
        table.concat(sent, ' | '))
    c:recv ':beta.example 219 me E :End of /STATS report'
    c:recv ':beta.example 703 me :End of /MODLIST.'
    T.eq(topo().drains, {}, 'no longer draining')
end)

T.case('rotations come from DNS', function()
    boot()
    HUB.current.routes['topology.refresh']()
    T.sleep(300)
    local main = topo().rotations.MAIN
    T.ok(main and (main['127.0.0.1'] or main['::1']), 'localhost resolved')
end)

T.case('feature commands need the feature', function()
    boot {features = {'snotice'}}
    local cmdline = T.require 'hub.ui.cmdline'
    T.require 'hub.ui.control'.init_state(HUB.state)
    cmdline.execute 'sync'
    local errors = T.log_lines 'error'
    T.eq(errors[#errors], 'sync needs the topology feature on test', 'refused')
end)

T.run()
