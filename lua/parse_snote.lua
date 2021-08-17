
local function scrub(str)
    return string.gsub(str, '%c', '~')
end

return function(time, server, str)

    local nick, user, host, ip, class, account, gecos = string.match(str, '^Client connecting: (%g+) %(([^@]+)@([^)]+)%) %[(.*)%] {([^}]*)} <([^>]*)> %[(.*)%]$')
    if nick then
        return {
            name = 'connect',
            server = server,
            nick = nick,
            user = user,
            host = host,
            ip = ip,
            gecos = scrub(gecos),
            time = time,
            class = class,
            account = account,
        }
    end

    local nick, user, host, reason, ip = string.match(str, '^Client exiting: (%g+) %(([^@]+)@([^)]+)%) %[(.*)%] %[(.*)%]$')
    if nick then
        return {
            name = 'disconnect',
            server = server,
            nick = nick,
            user = user,
            host = host,
            reason = scrub(reason),
            ip = ip,
            time = time,
        }
    end

    local nick, user, host, oper, duration, mask, reason = string.match(str, '^([^!]+)!([^@]+)@([^{]+){([^}]*)} added %g+ (%d+) min. K%-Line for %[([^]]*)%] %[(.*)%]$')
    if nick then
        return {
            name = 'kline',
            server = server,
            nick = nick,
            user = user,
            host = host,
            oper = oper,
            mask = mask,
            reason = scrub(reason),
            time = time,
        }

    end
    local old, new, user, host = string.match(str, '^Nick change: From (%g+) to (%g+) %[(%g+)@(%g+)%]$')
    if old then
        return {
            name = 'nick',
            server = server,
            old = old,
            new = new,
            user = user,
            host = host,
            time = time,
        }
    end

    local nick, user, host, ip = string.match(str, '^FILTER: ([^!]+)!([^@]+)@([^ ]+) %[(.*)%]$')
    if nick then
        return {
            name = 'filter',
            server = server,
            nick = nick,
            user = user,
            host = host,
            ip = ip,
            time = time,
        }
    end
end
