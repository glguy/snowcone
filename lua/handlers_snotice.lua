-- Logic for parsed snotices

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
    local entry = {
        server = ev.server,
        gecos = ev.gecos,
        host = ev.host,
        user = ev.user,
        nick = ev.nick,
        account = ev.account,
        ip = ev.ip,
        org = ip_org(ev.ip),
        time = ev.time,
        count = prev and prev.count+1 or 1,
        mask = ev.nick .. '!' .. ev.user .. '@' .. ev.host .. ' ' .. ev.gecos,
        timestamp = uptime,
    }
    users:insert(key, entry)

    conn_tracker:track(server)
    if show_entry(entry) then
        clicon_n = clicon_n + 1
    end

    local pop = population[ev.server]
    if pop then
        population[ev.server] = pop + 1
    end

    count_ip(ev.ip, 1)
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

    cliexit_n = cliexit_n + 1
    exits:insert(true, {
        nick = ev.nick,
        user = ev.user,
        host = ev.host,
        ip = ev.ip,
        reason = ev.reason,
        timestamp = uptime,
        time = ev.time,
        server = ev.server,
        org = ip_org(ev.ip),
        mask = ev.nick .. '!' .. ev.user .. '@' .. ev.host,
        gecos = (entry or {}).gecos,
    })

    count_ip(ev.ip, -1)
end

function M.nick(ev)
    local user = users:lookup(ev.old)
    if user then
        user.nick = ev.new
        users:rekey(ev.old, ev.new)
    end
end

function M.kline(ev)
    kline_tracker:track(ev.nick)
    klines:insert('kline ' .. ev.mask, {
        time = ev.time,
        oper = ev.oper,
        duration = ev.duration,
        reason = ev.reason,
        mask = ev.mask,
        kind = 'kline',
    })
end

function M.kill(ev)
    klines:insert('kill ' .. ev.nick, {
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

function M.rejected(ev)
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

        klines:insert(true, {
            time = ev.time,
            oper = ev.oper,
            mask = ev.mask,
            kind = 'removed'
        })
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
    snowcone.send_irc(counter_sync_commands())
    status_message = 'netjoin ' .. ev.server2
end

function M.netsplit(ev)
    snowcone.send_irc(counter_sync_commands())
    status_message = 'netsplit ' .. ev.server2 .. ' ('.. ev.reason .. ')'
end

function M.override(ev)
    status_message = string.format('override %s %s %s', ev.oper, ev.kind, ev.target)
end

return M
