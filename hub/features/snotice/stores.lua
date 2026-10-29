-- What server notices tell us, per network.
--
-- Notices may also send IRC: a reclaim when the wanted nick goes away. A
-- watch hit emits notify.alert instead of beeping.

local bus        <const> = require 'hub.runtime.bus'
local common     <const> = require 'hub.features.common'
local handlers   <const> = require 'hub.net.handlers'
local ip_org     <const> = require 'hub.features.snotice.ip_org'
local irc_model  <const> = require 'hub.net.irc'
local loadavg    <const> = require 'hub.lib.loadavg'
local matching   <const> = require 'hub.lib.matching'
local nettrack   <const> = require 'hub.features.snotice.nettrack'
local OrderedMap <const> = require 'hub.lib.OrderedMap'

local M = {}

M.sizes = {users = 1000, exits = 1000, klines = 1000, new_channels = 100}

--- A watch for connections whose mask matches pattern.
---@class hub.Watch
---@field pattern string
---@field active boolean
---@field hits integer
---@field colour string|nil
---@field beep boolean|nil
---@field flash boolean|nil
---@field from_config boolean|nil from the network's `watches`, replaced
--- whenever the configuration is applied; /addwatch ones stay

--- What server notices tell about a network, state.features.snotice[net].
---@class hub.Stores
---@field users hub.OrderedMap recent connections by nick; an entry gains
--- `reason` when the user exits and `filters` per FILTER hit
---@field exits hub.OrderedMap recent exits
---@field klines hub.OrderedMap bans, unbans and kills, keyed '<kind> <mask>'
---@field new_channels hub.OrderedMap channel creations, flooders and spambots
---@field trackers {conn: hub.LoadTracker, exit: hub.LoadTracker, kline: hub.LoadTracker, filter: hub.LoadTracker}
---@field net_trackers table<string, table<string, hub.Range>> ranges by
--- label, in trackers by name (nettrack.lua)
---@field watches hub.Watch[]

--- Fresh stores for a network record.
---@param rec hub.Network|nil
---@return hub.Stores
function M.new(rec)
    local casemapping = rec and rec.irc and rec.irc.casemapping or 'rfc1459'
    return {
        users = OrderedMap.new(M.sizes.users, casemapping),
        exits = OrderedMap.new(M.sizes.exits, casemapping),
        klines = OrderedMap.new(M.sizes.klines),
        new_channels = OrderedMap.new(M.sizes.new_channels, casemapping),
        trackers = {
            conn = loadavg.new_tracker(),
            exit = loadavg.new_tracker(),
            kline = loadavg.new_tracker(),
            filter = loadavg.new_tracker(),
        },
        net_trackers = {},
        watches = {},
    }
end

--- The stores of a network, created on first use.
---@param net string
---@return hub.Stores
function M.get(net)
    return common.net_state('snotice', net, M.new)
end

-- The wanted nick of a network became free
local function maybe_reclaim(net, nick)
    local rec = HUB.state.nets[net]
    local irc = rec and rec.irc
    if irc and irc.recover_nick and irc_model.fold(irc, nick) == irc.recover_nick then
        handlers.reclaim_nick(net)
    end
end

local function check_watches(S, ev, entry)
    local safematch = matching.safematch
    for _, watch in ipairs(S.watches) do
        if watch.active then
            local p = watch.pattern
            if safematch(entry.mask, p)
            or entry.org and safematch(entry.org, p)
            or entry.asn and safematch('AS' .. entry.asn, p)
            or entry.account and safematch(entry.account, p)
            or entry.ip and safematch(ev.nick .. '!' .. ev.user .. '@' .. ev.ip .. '#' .. ev.gecos, p)
            then
                watch.hits = watch.hits + 1
                entry.mark = watch.colour or 'red'
                bus.emit('notify.alert', {
                    net = ev.net,
                    kind = 'watch',
                    text = entry.mask,
                    beep = watch.beep,
                    flash = watch.flash,
                    colour = entry.mark,
                })
            end
        end
    end
end

local H = {}
M.handlers = H

function H.connect(S, ev)
    local prev = OrderedMap.lookup(S.users, ev.nick)

    local org, asn
    if ev.ip then
        org, asn = ip_org.lookup(ev.ip)
        nettrack.count_ip(S.net_trackers, ev.ip, 1)
    end

    local entry = {
        server = ev.server,
        gecos = ev.gecos,
        host = ev.host,
        user = ev.user,
        nick = ev.nick,
        account = ev.account,
        class = ev.class,
        ip = ev.ip,
        org = org,
        asn = math.tointeger(asn),
        time = ev.time,
        count = prev and prev.count + 1 or 1,
        mask = ev.nick .. '!' .. ev.user .. '@' .. ev.host .. '#' .. ev.gecos,
        timestamp = ev.timestamp,
    }
    OrderedMap.insert(S.users, ev.nick, entry)
    loadavg.track(S.trackers.conn, ev.server)
    check_watches(S, ev, entry)
end

function H.disconnect(S, ev)
    local entry = OrderedMap.lookup(S.users, ev.nick)
    loadavg.track(S.trackers.exit, ev.server)
    if entry then
        entry.reason = ev.reason
    end

    local org, asn
    if ev.ip then
        org, asn = ip_org.lookup(ev.ip)
        nettrack.count_ip(S.net_trackers, ev.ip, -1)
    end

    OrderedMap.insert(S.exits, nil, {
        nick = ev.nick,
        user = ev.user,
        host = ev.host,
        ip = ev.ip,
        reason = ev.reason,
        timestamp = ev.timestamp,
        time = ev.time,
        server = ev.server,
        org = org,
        asn = math.tointeger(asn),
        mask = ev.nick .. '!' .. ev.user .. '@' .. ev.host,
        gecos = entry and entry.gecos,
    })

    maybe_reclaim(ev.net, ev.nick)
end

function H.nick(S, ev)
    local user = OrderedMap.lookup(S.users, ev.old)
    if user then
        user.nick = ev.new
        user.mask = user.nick .. '!' .. user.user .. '@' .. user.host .. '#' .. (user.gecos or '')
        OrderedMap.rekey(S.users, ev.old, ev.new)
    end
    maybe_reclaim(ev.net, ev.old)
end

local function add_ban(S, ev, kind)
    OrderedMap.insert(S.klines, kind .. ' ' .. ev.mask, {
        timestamp = ev.timestamp,
        time = ev.time,
        oper = ev.oper,
        duration = ev.duration,
        reason = ev.reason,
        mask = ev.mask,
        kind = kind,
    })
end

function H.kline(S, ev)
    loadavg.track(S.trackers.kline, ev.oper)
    add_ban(S, ev, 'kline')
end

function H.dline(S, ev)
    local entry = OrderedMap.lookup(S.klines, 'dline ' .. ev.mask)
    if not entry or entry.kind ~= 'dline' then
        add_ban(S, ev, 'dline')
    end
end

function H.kill(S, ev)
    OrderedMap.insert(S.klines, 'kill ' .. ev.nick, {
        timestamp = ev.timestamp,
        time = ev.time,
        oper = ev.from,
        reason = ev.reason,
        mask = ev.nick,
        kind = 'kill',
    })
end

-- Count a nick against the ban that matched it
local function ban_hit(S, key, nick)
    local entry = OrderedMap.lookup(S.klines, key)
    if entry then
        local nicks = entry.nicks
        if nicks then
            nicks[nick] = (nicks[nick] or 0) + 1
        else
            entry.nicks = {[nick] = 1}
        end
    end
end

function H.kline_active(S, ev)
    ban_hit(S, 'kline ' .. ev.mask, ev.nick)
end

function H.dline_active(S, ev)
    ban_hit(S, 'dline ' .. ev.mask, ev.nick)
end

function H.rejected(S, ev)
    if ev.kind == 'k-line' then
        ban_hit(S, 'kline ' .. ev.mask, ev.nick)
    end
end

function H.expired(S, ev)
    if ev.kind == 'k-line' then
        local old = OrderedMap.lookup(S.klines, 'kline ' .. ev.mask)
        if old then
            old.kind = 'inactive'
        end
    end
end

local removed_kinds <const> = {
    ['k-line'] = {'kline ', 'unkline '},
    ['d-line'] = {'dline ', 'undline '},
}

function H.removed(S, ev)
    local kinds = removed_kinds[ev.kind]
    if not kinds then return end

    local old = OrderedMap.lookup(S.klines, kinds[1] .. ev.mask)
    if old then
        old.kind = 'inactive'
    end

    -- the same removal is often reported by several servers
    local key = kinds[2] .. ev.mask
    local _, newest = OrderedMap.each(S.klines)()
    if newest ~= key then
        OrderedMap.insert(S.klines, key, {
            timestamp = ev.timestamp,
            time = ev.time,
            oper = ev.oper,
            mask = ev.mask,
            kind = 'removed',
        })
    end
end

function H.filter(S, ev)
    loadavg.track(S.trackers.filter, ev.server)
    local user = OrderedMap.lookup(S.users, ev.nick)
    if user then
        user.filters = (user.filters or 0) + 1
    end
end

-- Flags on a new_channels entry
M.CREATE, M.FLOODER, M.SPAMBOT = 1, 2, 4

-- Consecutive notices about one nick share an entry
local function channel_flag(S, ev, channel, flag)
    local entry = OrderedMap.each(S.new_channels)()
    if entry == nil or entry.nick ~= ev.nick then
        OrderedMap.insert(S.new_channels, nil, {
            time = ev.time,
            timestamp = ev.timestamp,
            nick = ev.nick,
            channels = {channel},
            flags = {flag},
        })
    else
        entry.time = ev.time
        entry.timestamp = ev.timestamp
        for i, c in ipairs(entry.channels) do
            if c == channel then
                entry.flags[i] = entry.flags[i] | flag
                return
            end
        end
        table.insert(entry.channels, channel)
        table.insert(entry.flags, flag)
    end
end

function H.create_channel(S, ev)
    channel_flag(S, ev, ev.channel, M.CREATE)
end

function H.flooder(S, ev)
    channel_flag(S, ev, ev.target, M.FLOODER)
end

function H.spambot(S, ev)
    channel_flag(S, ev, ev.target, M.SPAMBOT)
end

--- Update a network's stores for a notice.
function M.apply(ev)
    local h = H[ev.name]
    if h then
        h(M.get(ev.net), ev)
    end
end

--- Advance every network's trackers by a second.
function M.tick()
    for net, S in pairs(HUB.state.features.snotice or {}) do
        if HUB.state.nets[net] then
            for _, tracker in pairs(S.trackers) do
                loadavg.tick(tracker)
            end
        end
    end
end

return M
