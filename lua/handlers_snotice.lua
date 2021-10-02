-- Logic for parsed snotices

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
        connected = true,
        count = prev and prev.count+1 or 1,
        mask = ev.nick .. '!' .. ev.user .. '@' .. ev.host .. ' ' .. ev.gecos,
        timestamp = uptime,
    }
    users:insert(key, entry)

    while users.n > history do
        users:pop_back()
    end
    conn_tracker:track(server)
    if show_entry(entry) then
        clicon_n = clicon_n + 1
    end

    local pop = population[ev.server]
    if pop then
        population[ev.server] = pop + 1
    end

    draw()
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
        entry.connected = false
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
    })
    while exits.n > history do
        exits:pop_back()
    end
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
    send_irc 'MAP\r\nLINKS\r\n'
end

function M.netsplit(ev)
    send_irc 'MAP\r\nLINKS\r\n'
end

return M
