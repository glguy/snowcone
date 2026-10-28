-- Network topology: server populations from MAP, links from LINKS,
-- versions, startup times, user shedding, and the addresses in each DNS
-- rotation.
--
-- state.features.topology[net] = {
--   population  [server] = users, from MAP and moved by connect/exit notices
--   links       [server] = {[server] = true}, from LINKS
--   upstream    [server] = its link towards primary_hub
--   versions    [server] = version text
--   uptimes     [server] = startup time text
--   sheds       [server] = shedding interval in seconds
--   rotations   [region] = {[address] = true}, refreshed every 30 s
-- }
--
-- Sending: MAP and LINKS at registration, on becoming an operator, and on
-- netsplits and netjoins; VERSION and STATS on request. All are queries.
--
-- Drains (the drain module) are not tracked for now; they and user
-- shedding are to be revisited together.

local bus       <const> = require 'hub.runtime.bus'
local clock     <const> = require 'hub.runtime.clock'
local common    <const> = require 'hub.features.common'
local log       <const> = require 'hub.runtime.log'
local N         <const> = require 'hub.lib.numerics'
local resources <const> = require 'hub.runtime.resources'
local send      <const> = require 'hub.net.send'
local task      <const> = require 'hub.runtime.task'
local timer     <const> = require 'hub.runtime.timer'

local M = {}

M.name = 'topology'
M.refresh_ms = 30000

-- STATS E line of a server that sheds users
local shed_pattern <const> = 'user shedding event +[0-9]+ +seconds %(frequency=([0-9]+)%)'

local function new_state()
    return {
        population = {},
        links = {},
        upstream = {},
        versions = {},
        uptimes = {},
        sheds = {},
        rotations = {},
    }
end

--- The topology of a network, created on first use.
function M.get(net)
    return common.net_state(M.name, net, new_state)
end

local function enabled(net)
    return common.enabled(net, M.name)
end

local function query(net, ...)
    local ok, err = pcall(send.send, net, ...)
    if not ok then
        log.add_net(net, 'topology', '%s', err)
    end
end

--- Ask for the server map and links again.
function M.sync(net)
    M.get(net).synced_at = clock.now()
    query(net, 'MAP')
    query(net, 'LINKS')
end

-- A sync this recent makes another one pointless
M.resync_after = 10

-- IRC replies =========================================================

local H = {}

-- "<client> :<map line>" ... until RPL_MAPEND
H[N.RPL_MAP] = function(T, msg)
    if not T.in_map then
        T.population = {}
        T.in_map = true
    end
    local server, count = (msg[2] or ''):match '(%g*)%[...%] %-* | Users: +(%d+)'
    if server then
        T.population[server] = math.tointeger(count)
    end
end

H[N.RPL_MAPEND] = function(T, _, net)
    T.in_map = nil
    bus.emit('topology.map', {net = net, population = T.population})
end

-- "<client> <version> <server> :<comments>"
H[N.RPL_VERSION] = function(T, msg)
    T.versions[msg.source] = (msg[2] or ''):match '%((.*)%)'
end

-- "<client> <server> <hub> :<hopcount> <info>"
H[N.RPL_LINKS] = function(T, msg)
    local partial = T.partial_links or {}
    T.partial_links = partial
    -- links go both ways; merge, since a server can appear in several
    -- replies (replacing its set would make the result depend on reply order)
    local server, linked = msg[2], msg[3]
    if server and linked and server ~= linked then
        partial[server] = partial[server] or {}
        partial[server][linked] = true
        partial[linked] = partial[linked] or {}
        partial[linked][server] = true
    end
end

H[N.RPL_ENDOFLINKS] = function(T, _, net)
    T.links = T.partial_links or {}
    T.partial_links = nil

    -- each server's next hop towards the primary hub
    local primary_hub = common.servers(net).primary_hub
    T.upstream = {}
    if primary_hub then
        T.upstream[primary_hub] = primary_hub
        local queue = {primary_hub}
        for _, here in ipairs(queue) do
            for k in pairs(T.links[here] or {}) do
                if not T.upstream[k] then
                    T.upstream[k] = here
                    table.insert(queue, k)
                end
            end
        end
    end
end

-- "<client> :Server Up <days> days, <hh>:<mm>:<ss>"
H[N.RPL_STATSUPTIME] = function(T, msg)
    local days, h, m, s = (msg[2] or ''):match ' (%d+) days, (%d+):(%d+):(%d+)$'
    if days then
        local startup = os.time() - 86400 * days - 3600 * h - 60 * m - s
        T.uptimes[msg.source] = os.date('!%Y-%m-%d %H:%M:%S', startup)
    end
end

-- Notices =============================================================

local function adjust_population(ev, delta)
    local T = M.get(ev.net)
    local pop = T.population[ev.server]
    if pop then
        T.population[ev.server] = pop + delta
    end
end

-- Check that a joining server still sheds users, and at what rate
local function check_shed(t, server)
    t:send('STATS', 'E', server)
    while true do
        local msg = t:wait_irc({N.RPL_STATSDEBUG, N.RPL_ENDOFSTATS}, 30000)
        if not msg then return end
        if msg.source == server then
            local T = M.get(t.net)
            if msg.command == N.RPL_STATSDEBUG and msg[2] == 'E' then
                local interval = (msg[3] or ''):match(shed_pattern)
                if interval then
                    T.sheds[server] = tonumber(interval)
                    return
                end
            elseif msg.command == N.RPL_ENDOFSTATS then
                T.sheds[server] = nil
                return
            end
        end
    end
end

local notices = {}

function notices.connect(ev) adjust_population(ev, 1) end
function notices.disconnect(ev) adjust_population(ev, -1) end

function notices.netjoin(ev)
    local net, server = ev.net, ev.server2
    local T = M.get(net)
    M.sync(net)
    log.add_net(net, 'snote', 'netjoin %s', server)
    if T.versions[server] ~= nil then
        T.versions[server] = nil
        query(net, 'VERSION', server)
    end
    if T.sheds[server] ~= nil then
        task.spawn('shed check', {net = net, owner = M.name}, check_shed, server)
    end
end

function notices.netsplit(ev)
    M.sync(ev.net)
    log.add_net(ev.net, 'snote', 'netsplit %s', ev.server2)
    M.get(ev.net).uptimes[ev.server2] = nil
end

function notices.shedding_on(ev)
    M.get(ev.net).sheds[ev.server] = ev.interval
end

function notices.shedding_off(ev)
    M.get(ev.net).sheds[ev.server] = nil
end

-- DNS rotations =======================================================

-- A lookup answers err_or_nil, addr...; keep every address
local function lookup_region(t, label, hostname)
    local results = table.pack(t:dnslookup(hostname))
    local T = M.get(t.net)
    if results[1] then
        log.add_net(t.net, 'dns', '%s: %s', hostname, results[1])
        T.rotations[label] = {}
        return
    end
    local set = {}
    for i = 2, results.n do
        set[results[i]] = true
    end
    T.rotations[label] = set
end
local function refresh_rotations()
    for net in pairs(HUB.state.features.topology or {}) do
        if HUB.state.nets[net] and enabled(net) then
            for label, region in pairs(common.servers(net).regions) do
                if region.hostname then
                    task.spawn('rotation ' .. label, {owner = M.name, net = net},
                        lookup_region, label, region.hostname)
                end
            end
        end
    end
end

-- Module interface ====================================================

function M.subscribe(sub)
    sub.on('irc.message', function(ev)
        if not enabled(ev.net) then return end
        local h = H[ev.msg.command]
        if h then h(M.get(ev.net), ev.msg, ev.net) end
    end)
    -- fill the server list at registration
    sub.on('net.registered', function(ev)
        if enabled(ev.net) then M.sync(ev.net) end
    end)
    sub.on('snote', function(ev)
        if not enabled(ev.net) then return end
        local h = notices[ev.name]
        if h then h(ev) end
    end)
    -- opers may see more, unless we just asked (a bouncer reports oper
    -- status right after registration)
    sub.on('irc.oper', function(ev)
        if not enabled(ev.net) then return end
        local last = M.get(ev.net).synced_at
        if not last or clock.now() - last >= M.resync_after then
            M.sync(ev.net)
        end
    end)
    sub.on('net.removed', function(ev) common.drop_state(M.name, ev.net) end)
end

-- Keep the rotation refresh running. The timer's id lives in state so a
-- reload doesn't start a second one.
function M.activate()
    local meta = HUB.state.features.topology_meta or {}
    HUB.state.features.topology_meta = meta
    if not (meta.timer and resources.get(meta.timer)) and HUB.boot.tick then
        meta.timer = timer.start(M.name, 0, 'topology.refresh')
    end
end

M.routes = {
    ['topology.refresh'] = function()
        local meta = HUB.state.features.topology_meta
        meta.timer = timer.start(M.name, M.refresh_ms, 'topology.refresh')
        refresh_rotations()
    end,
}

-- Commands ============================================================

local function servers_known(net)
    local T = M.get(net)
    local list = {}
    for server in pairs(T.population) do
        if common.servers(net).servers[server] then
            table.insert(list, server)
        end
    end
    table.sort(list)
    return list
end

M.commands = {
    {
        name = 'sync', spec = '', scope = 'net', feature = 'topology',
        help = 'Ask for MAP and LINKS again',
        fn = function(ctx) M.sync(ctx.net) end,
    },
    {
        name = 'versions', spec = '', scope = 'net', feature = 'topology',
        help = 'Ask every linked server for its version',
        fn = function(ctx)
            local T = M.get(ctx.net)
            T.versions = {}
            for server in pairs(T.links) do
                query(ctx.net, 'VERSION', server)
            end
        end,
    },
    {
        name = 'uptimes', spec = '', scope = 'net', feature = 'topology',
        help = 'Ask every linked server for its uptime',
        fn = function(ctx)
            local T = M.get(ctx.net)
            T.uptimes = {}
            for server in pairs(T.links) do
                query(ctx.net, 'STATS', 'u', server)
            end
        end,
    },
    {
        name = 'sheds', spec = '', scope = 'net', feature = 'topology',
        help = 'Find the servers shedding users',
        fn = function(ctx)
            local servers = servers_known(ctx.net)
            task.spawn('sheds', {net = ctx.net, owner = M.name}, function(t)
                local outstanding, found = {}, {}
                for _, server in ipairs(servers) do
                    outstanding[server] = true
                    t:send('STATS', 'E', server)
                end
                while next(outstanding) do
                    local msg = t:wait_irc({N.RPL_STATSDEBUG, N.RPL_ENDOFSTATS}, 30000)
                    if not msg then break end
                    if msg.command == N.RPL_STATSDEBUG and msg[2] == 'E' then
                        local interval = (msg[3] or ''):match(shed_pattern)
                        if interval then found[msg.source] = tonumber(interval) end
                    elseif msg.command == N.RPL_ENDOFSTATS then
                        outstanding[msg.source] = nil
                    end
                end
                M.get(t.net).sheds = found
                local names = {}
                for k in pairs(found) do table.insert(names, k) end
                table.sort(names)
                t:log('sheds', '%s', next(names) and 'Sheds active: ' .. table.concat(names, ' ')
                    or 'No sheds active')
            end)
        end,
    },
}

return M
