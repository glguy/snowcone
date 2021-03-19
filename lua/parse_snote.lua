
local function scrub(str)
    return string.gsub(str, '%c', '~')
end
    
return function(time, server, str)

    local nick, user, host, ip, class, gecos = string.match(str, '^Client connecting: (%g+) %(([^@]+)@([^)]+)%) %[(.*)%] {([^}]*)} %[(.*)%]$')
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
            reason = scrub(reason)
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
        }
    end
end
