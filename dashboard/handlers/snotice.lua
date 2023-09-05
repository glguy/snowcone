-- Logic for parsed snotices
local ip_org = require_ 'utils.ip_org'
local tablex = require 'pl.tablex'
local send = require 'utils.send'

local function count_ip(address, delta)
    if next(net_trackers) then
        local baddr = snowcone.pton(address)
        if baddr then
            for _, track in pairs(net_trackers) do
                track:delta(baddr, delta)
            end
        end
    end
end

local M = {}

function M.connect(ev)
    local key = ev.nick
    local server = ev.server

    local prev = users:lookup(key)

    local org, asn
    if ev.ip then
        org, asn = ip_org(ev.ip)
        count_ip(ev.ip, 1)
    end

    local entry = {
        server = ev.server,
        gecos = ev.gecos,
        host = ev.host,
        user = ev.user,
        nick = ev.nick,
        account = ev.account,
        ip = ev.ip,
        org = org,
        asn = math.tointeger(asn),
        time = ev.time,
        count = prev and prev.count+1 or 1,
        mask = ev.nick .. '!' .. ev.user .. '@' .. ev.host .. '#' .. ev.gecos,
        timestamp = uptime,
    }
    users:insert(key, entry)

    conn_tracker:track(server)

    local pop = population[ev.server]
    if pop then
        population[ev.server] = pop + 1
    end

    local function safematch(str, pat)
        local success, result = pcall(string.find, str, pat)
        return success and result
    end

    for _, watch in ipairs(watches) do
        if watch.active then
            if
                safematch(entry.mask, watch.mask) or
                entry.org and safematch(entry.org, watch.mask) or
                entry.asn and safematch('AS'..entry.asn, watch.mask) or
                entry.ip  and safematch(ev.nick .. '!' .. ev.user .. '@' .. ev.ip .. '#' .. ev.gecos, watch.mask)
            then
                watch.hits = watch.hits + 1
                entry.mark = watch.color or ncurses.red
                if watch.beep  then ncurses.beep () end
                if watch.flash then ncurses.flash() end
            end
        end
    end
end

function M.disconnect(ev)
    local key = ev.nick
    local entry = users:lookup(key)

    exit_tracker:track(ev.server)
    local pop = population[ev.server]
    if pop then
        population[ev.server] = pop - 1
    end

    if entry then
        entry.reason = ev.reason
        draw()
    end

    local org, asn
    if ev.ip then
        org, asn = ip_org(ev.ip)
        count_ip(ev.ip, -1)
    end

    exits:insert(nil, {
        nick = ev.nick,
        user = ev.user,
        host = ev.host,
        ip = ev.ip,
        reason = ev.reason,
        timestamp = uptime,
        time = ev.time,
        server = ev.server,
        org = org,
        asn = asn,
        mask = ev.nick .. '!' .. ev.user .. '@' .. ev.host,
        gecos = (entry or {}).gecos,
    })

    if irc_state.target_nick == ev.nick then
        send('NICK', irc_state.target_nick)
    end
end

function M.nick(ev)
    local user = users:lookup(ev.old)
    if user then
        user.nick = ev.new
        users:rekey(ev.old, ev.new)
    end

    if irc_state.target_nick == ev.old then
        send('NICK', irc_state.target_nick)
    end
end

function M.kline(ev)
    kline_tracker:track(ev.oper)
    klines:insert('kline ' .. ev.mask, {
        timestamp = uptime,
        time = ev.time,
        oper = ev.oper,
        duration = ev.duration,
        reason = ev.reason,
        mask = ev.mask,
        kind = 'kline',
    })
end

function M.dline(ev)
    local key = 'dline ' .. ev.mask
    local entry = klines:lookup(key)
    if not entry or entry.kind ~= 'dline' then
        klines:insert(key, {
            timestamp = uptime,
            time = ev.time,
            oper = ev.oper,
            duration = ev.duration,
            reason = ev.reason,
            mask = ev.mask,
            kind = 'dline',
        })
    end
end

function M.kill(ev)
    klines:insert('kill ' .. ev.nick, {
        timestamp = uptime,
        time = ev.time,
        oper = ev.from,
        reason = ev.reason,
        mask = ev.nick,
        kind = 'kill',
    })
end

function M.kline_active(ev)
    local entry = klines:lookup('kline ' .. ev.mask)
    if entry then
        local nicks = entry.nicks
        if nicks then
            nicks[ev.nick] = (nicks[ev.nick] or 0) + 1
        else
            entry.nicks = { [ev.nick] = 1 }
        end
    end
end

function M.dline_active(ev)
    local entry = klines:lookup('dline ' .. ev.mask)
    if entry then
        local nicks = entry.nicks
        if nicks then
            nicks[ev.nick] = (nicks[ev.nick] or 0) + 1
        else
            entry.nicks = { [ev.nick] = 1 }
        end
    end
end

function M.rejected(ev)
    if ev.kind == 'k-line' then
        local entry = klines:lookup('kline ' .. ev.mask)
        if entry then
            local nicks = entry.nicks
            if nicks then
                nicks[ev.nick] = (nicks[ev.nick] or 0) + 1
            else
                entry.nicks = { [ev.nick] = 1 }
            end
        end
    end
end

function M.expired(ev)
    if ev.kind == 'k-line' then
        local old = klines:lookup('kline ' .. ev.mask)
        if old then
            old.kind = 'inactive'
        end
    end
end

function M.removed(ev)
    if ev.kind == 'k-line' then
        local old = klines:lookup('kline ' .. ev.mask)
        if old then
            old.kind = 'inactive'
        end

        local _, prev_key = klines:each()()
        local key = 'unkline ' .. ev.mask
        if prev_key ~= key then
            klines:insert(key, {
                timestamp = uptime,
                time = ev.time,
                oper = ev.oper,
                mask = ev.mask,
                kind = 'removed'
            })
        end

    elseif ev.kind == 'd-line' then
        local old = klines:lookup('dline ' .. ev.mask)
        if old then
            old.kind = 'inactive'
        end

        local _, prev_key = klines:each()()
        local key = 'undline ' .. ev.mask
        if prev_key ~= key then
            klines:insert(key, {
                timestamp = uptime,
                time = ev.time,
                oper = ev.oper,
                mask = ev.mask,
                kind = 'removed'
            })
        end
    end
end

function M.filter(ev)
    filter_tracker:track(ev.server)
    local mask = ev.nick
    local user = users:lookup(mask)
    if user then
        user.filters = (user.filters or 0) + 1
    end
end

function M.netjoin(ev)
    counter_sync_commands()
    status('snote', 'netjoin %s', ev.server2)

    if versions[ev.server2] ~= nil then
        versions[ev.server2] = nil
        send('VERSION', ev.server2)
    end
end

function M.netsplit(ev)
    counter_sync_commands()
    status('snote', 'netsplit %s', ev.server2)
    uptimes[ev.server2] = nil
end

function M.override(ev)
    status('snote', 'override %s %s %s', ev.oper, ev.kind, ev.target)
end

function M.operspy(ev)
    status('snote', 'operspy %s %s %s', ev.oper, ev.token, ev.arg)
end

function M.grant(ev)
    status('snote', 'grant by %s for %s to %s', ev.oper, ev.target, ev.privset)
end

function M.ungrant(ev)
    status('snote', 'ungrant by %s for %s', ev.oper, ev.target)
end

local function channel_flag(time, nick, channel, flag)
    local entry = new_channels:each()()
    if entry == nil or entry.nick ~= nick then
        entry = { time = time, timestamp = uptime, nick = nick, channels = {channel}, flags = {flag} }
        new_channels:insert(nil, entry)
    else
        entry.time = time
        entry.timestamp = uptime
        local i = tablex.find(entry.channels, channel)
        if i then
            entry.flags[i] = entry.flags[i] | flag
        else
            table.insert(entry.channels, channel)
            table.insert(entry.flags, flag)
        end
    end
end

function M.create_channel(ev)
    channel_flag(ev.time, ev.nick, ev.channel, 1)
end

function M.flooder(ev)
    channel_flag(ev.time, ev.nick, ev.target, 2)
end

function M.spambot(ev)
    channel_flag(ev.time, ev.nick, ev.target, 4)
end

return M
