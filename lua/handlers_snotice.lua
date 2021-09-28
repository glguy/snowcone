-- Logic for parsed snotices

local M = {}

function M.connect(ev)
    local key = ev.nick
    local server = ev.server

    local entry = users:insert(key, {count = 0})
    entry.server = ev.server
    entry.gecos = ev.gecos
    entry.host = ev.host
    entry.user = ev.user
    entry.nick = ev.nick
    entry.account = ev.account
    entry.ip = ev.ip
    entry.time = ev.time
    entry.connected = true
    entry.count = entry.count + 1
    entry.mask = entry.nick .. '!' .. entry.user .. '@' .. entry.host .. ' ' .. entry.gecos
    entry.org = ip_org(entry.ip)
    entry.timestamp = uptime

    while users.n > history do
        users:delete(users:last_key())
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
    while exits.n > history do
        exits:delete(exits:last_key())
    end
    local entry = {
        nick = ev.nick,
        user = ev.user,
        host = ev.host,
        ip = ev.ip,
        reason = ev.reason,
        timestamp = uptime,
        time = ev.time,
        server = ev.server,
        org = ip_org(ev.ip),
    }
    ev.timestamp = uptime
    exits:insert(cliexit_n, entry)
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

return M
