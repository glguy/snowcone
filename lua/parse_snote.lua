-- Logic for breaking down server notices into semantic notice objects

local repls = {
    ['\x00'] = '␀', ['\x01'] = '␁', ['\x02'] = '␂', ['\x03'] = '␃',
    ['\x04'] = '␄', ['\x05'] = '␅', ['\x06'] = '␆', ['\x07'] = '␇',
    ['\x08'] = '␈', ['\x09'] = '␉', ['\x0a'] = '␤', ['\x0b'] = '␋',
    ['\x0c'] = '␌', ['\x0d'] = '␍', ['\x0e'] = '␎', ['\x0f'] = '␏',
    ['\x10'] = '␐', ['\x11'] = '␑', ['\x12'] = '␒', ['\x13'] = '␓',
    ['\x14'] = '␔', ['\x15'] = '␕', ['\x16'] = '␖', ['\x17'] = '␗',
    ['\x18'] = '␘', ['\x19'] = '␙', ['\x1a'] = '␚', ['\x1b'] = '␛',
    ['\x1c'] = '␜', ['\x1d'] = '␝', ['\x1e'] = '␞', ['\x1f'] = '␟',
    ['\x7f'] = '␡',
}
local function scrub(str)
    return string.gsub(str, '%c', repls)
end

return function(time, server, str)
    do
        local nick, user, host, ip, class, account, gecos =
            string.match(str, '^Client connecting: (%g+) %(([^@]+)@([^)]+)%) %[(.*)%] {([^}]*)} <([^>]*)> %[(.*)%]$')
        if nick then
            return {
                name = 'connect',
                server = server,
                time = time,
                nick = nick,
                user = user,
                host = host,
                ip = ip,
                gecos = scrub(gecos),
                class = class,
                account = account,
            }
        end
    end

    do
        local nick, user, host, reason, ip =
            string.match(str, '^Client exiting: (%g+) %(([^@]+)@([^)]+)%) %[(.*)%] %[(.*)%]$')
        if nick then
            return {
                name = 'disconnect',
                server = server,
                time = time,
                nick = nick,
                user = user,
                host = host,
                reason = scrub(reason),
                ip = ip,
            }
        end
    end

    do
        local nick, user, host, oper, duration, mask, reason =
            string.match(str, '^([^!]+)!([^@]+)@([^{]+){([^}]*)} \z
                               added %g+ (%d+) min%. K%-Line for %[([^]]*)%] %[(.*)%]$')
        if nick then
            return {
                name = 'kline',
                server = server,
                time = time,
                nick = nick,
                user = user,
                host = host,
                oper = oper,
                mask = mask,
                duration = duration,
                reason = scrub(reason),
            }
        end
    end

    do
        local old, new, user, host =
            string.match(str, '^Nick change: From (%g+) to (%g+) %[(%g+)@(%g+)%]$')
        if old then
            return {
                name = 'nick',
                server = server,
                time = time,
                old = old,
                new = new,
                user = user,
                host = host,
            }
        end
    end

    do
        local nick, user, host, ip =
            string.match(str, '^FILTER: ([^!]+)!([^@]+)@([^ ]+) %[(.*)%]$')
        if nick then
            return {
                name = 'filter',
                server = server,
                time = time,
                nick = nick,
                user = user,
                host = host,
                ip = ip,
            }
        end
    end

    do
        local server1, server2, sid1, sid2, reason =
            string.match(str, '^Netsplit (%g+) <%-> (%g+) %((%g+) (%g+)%) %((.*)%)$')
        if server1 then
            return {
                name = 'netsplit',
                server = server,
                time = time,
                server1 = server1,
                server2 = server2,
                sid1 = sid1,
                sid2 = sid2,
                reason = reason,
            }
        end
    end

    do
        local server1, server2, sid1, sid2, reason =
            string.match(str, '^Netjoin (%g+) <%-> (%g+) %((%g+) (%g+)%)$')
        if server1 then
            return {
                name = 'netjoin',
                server = server,
                time = time,
                server1 = server1,
                server2 = server2,
                sid1 = sid1,
                sid2 = sid2,
                reason = reason,
            }
        end
    end
end
