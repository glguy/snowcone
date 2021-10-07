-- Logic for breaking down server notices into semantic notice objects

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
                reason = scrub(reason),
            }
        end
    end

    do
        local server1, server2, sid1, sid2 =
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
            }
        end
    end

    do
        local nick, user, host, oper, token, arg =
            string.match(str, '^OPERSPY ([^!]+)!([^@]+)@([^{]+){([^}]*)} (%g+) (.*)$')
        if oper then
            return {
                name = 'operspy',
                server = server,
                time = time,
                nick = nick,
                user = user,
                host = host,
                oper = oper,
                token = token,
                arg = arg,
            }
        end
    end

    do
        local nick, user, host, oper, target, kind =
            string.match(str, '^([^!]+)!([^@]+)@([^{]+){([^}]*)} \z
                               is using oper%-override on (%g+) %((.*)%)$')
        if nick then
            return {
                name = 'override',
                server = server,
                time = time,
                nick = nick,
                user = user,
                host = host,
                oper = oper,
                target = target,
                kind = kind,
            }
        end
    end
end
