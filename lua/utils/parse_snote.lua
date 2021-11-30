-- Logic for breaking down server notices into semantic notice objects

local simple = {
    ['Filtering enabled.'] = 'filtering_enabled',
    ['Filtering disabled.'] = 'filtering_disabled',
    ['New filters loaded.'] = 'filtering_loaded',
    ['Got signal SIGUSR1, reloading ircd motd file'] = 'rehash_motd',
    ['Got signal SIGHUP, reloading ircd conf. file'] = 'rehash_config',
}

-- luacheck: ignore 631
return function(time, server, str)
    do
        local nick, user, host, ip, class, account, gecos =
            string.match(str, '^Client connecting: (%S+) %(([^@ ]+)@([^) ]+)%) %[(.*)%] {(%S*)} <(%S*)> %[(.*)%]$')
        if nick then
            if ip == '0' then ip = nil end
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
            string.match(str, '^Client exiting: (%S+) %(([^@ ]+)@([^) ]+)%) %[(.*)%] %[(.*)%]$')
        if nick then
            if ip == '0' then ip = nil end
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
            string.match(str, '^([^!]+)!([^@]+)@([^{]+){([^}]*)} added %S+ (%d+) min%. (%S+) for %[(%S*)%] %[(.*)%]$')
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
            string.match(str, '^Nick change: From (%S+) to (%S+) %[([^@ ]+)@(%S+)%]$')
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
            string.match(str, '^FILTER: ([^! ]+)!([^@ ]+)@(%S+) %[(.*)%]$')
        if nick then
            if ip == '0' then ip = nil end
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
            string.match(str, '^KLINE active for (%S+)%[([^@ ]+)@(%S+)%] %((.*)%)$')
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
            string.match(str, '^Disconnecting K%-Lined user (%S+)%[([^@ ]+)@(%S+)%] %((.*)%)$')
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
            string.match(str, '^Temporary (%S+) for %[(.*)%] expired$')
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
            string.match(str, '^([^! ]+)!([^@ ]+)@([^{ ]+){(%S*)} has removed the %S+ (%S+) for: %[(.*)%]$')
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
            string.match(str, '^Rejecting (%S+)d user (%S+)%[([^@ ]+)@(%S+)%] %[(.*)%]$')
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
            string.match(str, '^Rejecting (%S+)d user (%S+)%[([^@ ]+)@(%S+)%] %[(%S*)%] %((.*)%)$')
        if nick then
            if ip == '0' then ip = nil end
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
            string.match(str, '^Netsplit (%S+) <%-> (%S+) %((%S+) (%S+)%) %((.*)%)$')
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
            string.match(str, '^Netjoin (%S+) <%-> (%S+) %((%S+) (%S+)%)$')
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
            string.match(str, '^Received KILL message for ([^! ]+)!([^@ ]+)@(%S+)%. From (%S+) Path: %S+ %((.*)%)$')
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
            string.match(str, '^Received KILL message for ([^! ]+)!([^@ ]+)@(%S+)%. From (%S+) %((.*)%)$')
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
            string.match(str, '^Possible Flooder (%S+)%[([^@ ]+)@(%S+)%] on %S+ target: (%S+)$')
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
            string.match(str, '^User (%S+) %(([^@ ]+)@(%S*)%) trying to join (%S+) is a possible spambot$')
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
            string.match(str, '^Excessive target change from (%S+) %(([^@ ]+)@(.*)%)$')
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
            string.match(str, '^(%S+) is creating new channel (%S+)$')
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
            string.match(str, '^OPERSPY ([^! ]+)!([^@ ]+)@([^{ ]+){([^} ]*)} (%S+) (.*)$')
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
            string.match(str, '^([^! ]+)!([^@ ]+)@([^{]+){([^}]*)} is using oper%-override on (%S+) %((.*)%)$')
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

    do -- old format
        local kind, nick, user, host =
            string.match(str, '^Too many (%S+) connections for ([^! ]+)!([^@ ]+)@(%S+)$')
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

    do -- new format bd38559fedcdfded4d9acbcbf988e4a8f5057eeb
        local kind, nick, user, host, ip =
        string.match(str, '^Too many (%S+) connections for (%S+)%[([^@ ]+)@(%S+)%] %[(.*)%]$')
        if ip == '0' then ip = nil end
        if kind then
            return {
                name = 'toomany',
                server = server,
                time = time,
                nick = nick,
                user = user,
                host = host,
                kind = kind,
                ip = ip,
            }
        end
    end

    do -- SASL login failure
        local count, account, host =
            string.match(str, '^Warning: \x02([^\x02]+)\x02 failed login attempts to \x02([^\x02]+)\x02%. Last attempt received from \x02<Unknown user on %S+ %(via SASL%):([^\x02]+)>\x02')
        if count then
            return {
                name = 'badlogin',
                server = server,
                time = time,
                count = tonumber(count),
                account = account,
                host = host,
            }
        end
    end

    do -- NickServ login failure
        local count, account, nick, user, host =
            string.match(str, '^Warning: \x02([^\x02]+)\x02 failed login attempts to \x02([^\x02]+)\x02%. Last attempt received from \x02([^!]+)!([^@]+)@([^\x02]+)\x02')
        if count then
            return {
                name = 'badlogin',
                server = server,
                time = time,
                count = tonumber(count),
                account = account,
                host = host,
                nick = nick,
                user = user,
            }
        end
    end

    do
        local nick, user, host =
            string.match(str, '^(%S+) %(([^@ ]*)@(%S*)%) is now an operator$')
        if nick then
            return {
                name = 'oper',
                server = server,
                time = time,
                host = host,
                nick = nick,
                user = user,
            }
        end
    end

    -- Previous implementation, useful for oftc-hybrid
    do
        local nick, user, host, ip, class, gecos =
            string.match(str, '^Client connecting: (%S+) %(([^@ ]+)@(%S+)%) %[(%S*)%] {(%S*)} %[(.*)%]$')
        if nick then
            if ip == '0' then ip = nil end
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

    do
        local name = simple[str]
        if name then
            return {
                name = name,
                server = server,
                time = time,
            }
        end
    end
end
