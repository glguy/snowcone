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
                gecos = gecos,
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
                reason = reason,
                ip = ip,
            }
        end
    end

    do
        local nick, user, host, oper, duration, kind, mask, reason =
            string.match(str, '^([^!]+)!([^@]+)@([^{]+){([^}]*)} \z
                               added %g+ (%d+) min%. (%g+) for %[([^]]*)%] %[(.*)%]$')
        if nick then
            local names = {
                ['K-Line'] = 'kline',
                ['X-Line'] = 'xline',
                ['D-Line'] = 'dline',
                ['RESV'] = 'resv',
            }

            return {
                name = assert(names[kind]),
                server = server,
                time = time,
                nick = nick,
                user = user,
                host = host,
                oper = oper,
                mask = mask,
                duration = math.tointeger(duration),
                reason = reason,
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
            string.match(str, '^Disconnecting K%-Lined user (%g-)%[(%g-)@(%g-)%] %((.*)%)$')
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

    do -- old format
        local kind, nick, user, host, mask =
            string.match(str, '^Rejecting (%g+)d user (%g-)%[(%g-)@(%g-)%] %[(%g+)%]$')
        if nick then
            return {
                name = 'rejected',
                server = server,
                time = time,
                nick = nick,
                user = user,
                host = host,
                mask = mask,
                kind = string.lower(kind),
            }
        end
    end

    do -- new format
        local kind, nick, user, host, ip, mask =
            string.match(str, '^Rejecting (%g+)d user (%g-)%[(%g-)@(%g-)%] %[(%g+)%] %((.*)%)$')
        if nick then
            return {
                name = 'rejected',
                server = server,
                time = time,
                nick = nick,
                user = user,
                host = host,
                mask = mask,
                ip = ip,
                kind = string.lower(kind), -- k-line, x-line
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
                reason = reason,
            }
        end
    end

    do -- some kills don't have paths
        local nick, user, host, from, reason =
            string.match(str, '^Received KILL message for (.-)!(.-)@(.-)%. From (%g+) %((.*)%)$')
        if nick then
            return {
                name = 'kill',
                server = server,
                time = time,
                nick = nick,
                user = user,
                host = host,
                from = from,
                reason = reason,
            }
        end
    end

    do
        local clients = string.match(str, '^New Max Local Clients: (%d+)$')
        if clients then
            return {
                name = 'newmaxlocal',
                server = server,
                time = time,
                clients = math.tointeger(clients),
            }
        end
    end

    do
        local nick, user, host, target =
            string.match(str, '^Possible Flooder ([^[]+)%[([^@]+)@([^]]+)%] on %g+ target: (%g+)$')
        if nick then
            return {
                name = 'flooder',
                server = server,
                time = time,
                nick = nick,
                user = user,
                host = host,
                target = target,
            }
        end
    end

    do
        local nick, user, host, target =
            string.match(str, '^User (%g+) %(([^@]*)@([^)]*)%) trying to join (%g+) is a possible spambot$')
        if nick then
            return {
                name = 'spambot',
                server = server,
                time = time,
                nick = nick,
                user = user,
                host = host,
                target = target,
            }
        end
    end

    do
        local nick, user, host =
            string.match(str, '^Excessive target change from (%g+) %((.-)@(.*)%)$')
        if nick then
            return {
                name = 'targetchange',
                server = server,
                time = time,
                nick = nick,
                user = user,
                host = host,
            }
        end
    end

    do
        local nick, channel =
            string.match(str, '^(%g+) is creating new channel (%g+)$')
        if nick then
            return {
                name = 'create_channel',
                server = server,
                time = time,
                nick = nick,
                channel = channel,
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

    do
        if str == 'Filtering enabled.' then
            return {
                name = 'filteringenabled',
                server = server,
                time = time,
            }
        end
    end

    do
        if str == 'Filtering disabled.' then
            return {
                name = 'filteringdisabled',
                server = server,
                time = time,
            }
        end
    end

    do
        if str == 'New filters loaded.' then
            return {
                name = 'filtersloaded',
                server = server,
                time = time,
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
                gecos = gecos,
                class = class,
            }
        end
    end
end
