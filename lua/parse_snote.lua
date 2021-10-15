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
        local nick, user, host, mask =
            string.match(str, '^KLINE active for (.-)%[(.-)@(.-)%] %((.*)%)$')
            if nick then
                return {
                    name = 'kline_active',
                    server = server,
                    time = time,
                    nick = nick,
                    user = user,
                    host = host,
                    mask = mask,
                }
            end
    end

    do -- new format added in 430833dca2fc08ae6f423ff6bded4bffeb5d345a
        local nick, user, host, mask =
            string.match(str, '^Disconnecting K-Lined user (.-)%[(.-)@(.-)%] %((.*)%)$')
            if nick then
                return {
                    name = 'kline_active',
                    server = server,
                    time = time,
                    nick = nick,
                    user = user,
                    host = host,
                    mask = mask,
                }
            end
    end

    do
        local kind, mask =
            string.match(str, '^Temporary (%g+) for %[(.*)%] expired$')
        if kind then
            return {
                name = 'expired',
                server = server,
                time = time,
                kind = string.lower(kind), -- resv, k-line, x-line
                mask = mask,
            }
        end
    end

    do
        local mask =
            string.match(str, '^Propagated ban for %[(.*)%] expired$')
        if mask then
            return {
                name = 'expired',
                server = server,
                time = time,
                kind = 'k-line',
                mask = mask,
            }
        end
    end

    do
        local nick, user, host, oper, kind, mask =
            string.match(str, '^([^!]+)!([^@]+)@([^{]+){([^}]*)} \z
                               has removed the %g+ (%g+) for: %[(.*)%]$')
        if nick then
            return {
                name = 'removed',
                server = server,
                time = time,
                nick = nick,
                user = user,
                host = host,
                oper = oper,
                kind = string.lower(kind),
                mask = mask,
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
        local nick, user, host, from, reason =
            string.match(str, '^Received KILL message for (.-)!(.-)@(.-)%. From (%g+) Path: %g+ %((.*)%)$')
        if nick then
            return {
                name = 'kill',
                server = server,
                time = time,
                nick = nick,
                user = user,
                host = host,
                from = from,
                reason = scrub(reason),
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

    do
        local kind, nick, user, host =
            string.match(str, '^Too many (%g+) connections for ([^!]+)!([^@]+)@(.+)$')
        if kind then
            return {
                name = 'toomany',
                server = server,
                time = time,
                nick = nick,
                user = user,
                host = host,
                kind = kind,
            }
        end
    end

    -- Previous implementation, useful for oftc-hybrid
    do
        local nick, user, host, ip, class, gecos =
            string.match(str, '^Client connecting: (%g+) %(([^@]+)@([^)]+)%) %[(.*)%] {([^}]*)} %[(.*)%]$')
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
            }
        end
    end
end
