-- Solanum's server notice parser. The caller stamps the time.
--
-- parse(server, text) returns a flat record with `name` and the
-- notice's fields, or nil. Each pattern is a notice Solanum, its
-- extensions or services through it send. tests/hub/test-snotice.lua
-- replays recorded notices against their expected parses.

local simple = {
    ['Filtering enabled.'] = 'filtering_enabled',
    ['Filtering disabled.'] = 'filtering_disabled',
    ['New filters loaded.'] = 'filtering_loaded',
    ['Got signal SIGUSR1, reloading ircd motd file'] = 'rehash_motd',
    ['Got signal SIGHUP, reloading ircd conf. file'] = 'rehash_config',
}

-- luacheck: ignore 631
return function(server, str)
    do
        local nick, user, host, ip, class, account, gecos =
            string.match(str, '^Client connecting: (%S+) %(([^@ ]+)@([^) ]+)%) %[([^%] ]*)%] {([^} ]*)} <([^> ]*)> %[(.*)%]$')
        if nick then
            if ip == '0' then ip = nil end
            return {
                name = 'connect',
                server = server,
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
                nick = nick,
                user = user,
                host = host,
                reason = reason,
                ip = ip,
            }
        end
    end

    -- "<oper> added global|temporary <n> min. K-Line for [<mask>] [<reason>]",
    -- and without "global|temporary <n> min." when permanent
    do
        local nick, user, host, oper, rest =
            string.match(str, '^([^!]+)!([^@]+)@([^{]+){([^}]*)} added (.*)$')
        local duration, kind, mask, reason
        if nick then
            duration, kind, mask, reason =
                string.match(rest, '^%a+ (%d+) min%. (%S+) for %[(%S*)%] %[(.*)%]$')
            if not duration then
                kind, mask, reason = string.match(rest, '^(%S+) for %[(%S*)%] %[(.*)%]$')
            end
        end
        local names = {
            ['K-Line'] = 'kline',
            ['X-Line'] = 'xline',
            ['D-Line'] = 'dline',
            ['RESV'] = 'resv',
        }
        if names[kind] then
            return {
                name = names[kind],
                server = server,
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
                nick = nick,
                user = user,
                host = host,
                ip = ip,
            }
        end
    end

    do
        local nick, user, host, mask =
            string.match(str, '^Disconnecting K%-Lined user (%S+)%[([^@ ]+)@(%S+)%] %((.*)%)$')
        if nick then
            return {
                name = 'kline_active',
                server = server,
                nick = nick,
                user = user,
                host = host,
                mask = mask,
            }
        end
    end

    do
        local nick, user, host, mask =
            string.match(str, '^Disconnecting D%-Lined user (%S+)%[([^@ ]+)@(%S+)%] %((.*)%)$')
        if nick then
            return {
                name = 'dline_active',
                server = server,
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
                kind = 'k-line',
                mask = mask,
            }
        end
    end

    -- "<oper> has removed the [global |temporary ]K-Line for: [<mask>]"
    do
        local nick, user, host, oper, kind, mask =
            string.match(str, '^([^! ]+)!([^@ ]+)@([^{ ]+){(%S*)} has removed the (%S+) for: %[(.*)%]$')
        if not nick then
            nick, user, host, oper, kind, mask =
                string.match(str, '^([^! ]+)!([^@ ]+)@([^{ ]+){(%S*)} has removed the %a+ (%S+) for: %[(.*)%]$')
        end
        if nick then
            return {
                name = 'removed',
                server = server,
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
        local kind, nick, user, host, ip, mask =
            string.match(str, '^Rejecting (%S+)d user (%S+)%[([^@ ]+)@(%S+)%] %[(%S*)%] %((.*)%)$')
        if nick then
            if ip == '0' then ip = nil end
            return {
                name = 'rejected',
                server = server,
                nick = nick,
                user = user,
                host = host,
                mask = mask,
                ip = ip,
                kind = string.lower(kind), -- k-line, x-line
            }
        end
    end

    -- server1 is server2's uplink; the counts are the servers and users
    -- behind server2, which a split during its burst doesn't have
    do
        local server1, server2, servers, users, reason =
            string.match(str, '^Netsplit (%S+) <%-> (%S+) %((%d+)S (%d+)C%) %((.*)%)$')
        if not server1 then
            server1, server2, reason =
                string.match(str, '^Netsplit (%S+) <%-> (%S+) %(during burst%) %((.*)%)$')
        end
        if server1 then
            return {
                name = 'netsplit',
                server = server,
                server1 = server1,
                server2 = server2,
                servers = math.tointeger(servers),
                users = math.tointeger(users),
                reason = reason,
            }
        end
    end

    do
        local server1, server2, servers, users =
            string.match(str, '^Netjoin (%S+) <%-> (%S+) %((%d+)S (%d+)C%)$')
        if server1 then
            return {
                name = 'netjoin',
                server = server,
                server1 = server1,
                server2 = server2,
                servers = math.tointeger(servers),
                users = math.tointeger(users),
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
        local kind, nick, user, host, ip =
        string.match(str, '^Too many (%S+) connections for (%S+)%[([^@ ]+)@(%S+)%] %[(.*)%]$')
        if ip == '0' then ip = nil end
        if kind then
            return {
                name = 'toomany',
                server = server,
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
                count = tonumber(count),
                account = account,
                host = host,
                nick = nick,
                user = user,
            }
        end
    end

    -- "<oper> (<nick>!<user>@<host>) is now an operator" from the server,
    -- "<nick> (<user>@<host>) ..." for one on another server
    do
        local oper, nick, user, host =
            string.match(str, '^(%S+) %(([^! ]+)!([^@ ]*)@(%S*)%) is now an operator$')
        if not oper then
            nick, user, host = string.match(str, '^(%S+) %(([^@ ]*)@(%S*)%) is now an operator$')
        end
        if nick then
            return {
                name = 'oper',
                server = server,
                host = host,
                nick = nick,
                user = user,
                oper = oper,
            }
        end
    end

    do
        local nick, user, host, oper, target, privset =
        string.match(str, '^([^! ]+)!([^@ ]+)@([^{]+){([^}]*)} is opering (%S+) with privilege set (%S+)$')
        if oper then
            return {
                name = 'grant',
                server = server,
                nick = nick,
                user = user,
                host = host,
                oper = oper,
                target = target,
                privset = privset,
            }
        end
    end

    do
        local nick, user, host, oper, target, privset =
        string.match(str, '^([^! ]+)!([^@ ]+)@([^{]+){([^}]*)} is changing the privilege set of (%S+) to (%S+)$')
        if oper then
            return {
                name = 'grant',
                server = server,
                nick = nick,
                user = user,
                host = host,
                oper = oper,
                target = target,
                privset = privset,
            }
        end
    end

    do
        local nick, user, host, oper, target =
        string.match(str, '^([^! ]+)!([^@ ]+)@([^{]+){([^}]*)} is deopering (%S+)%.$')
        if oper then
            return {
                name = 'ungrant',
                server = server,
                nick = nick,
                user = user,
                host = host,
                oper = oper,
                target = target,
            }
        end
    end

    do
        local module =
        string.match(str, '^Module ([^ ]+) %[.*%] loaded at [^ ]+$')
        if module then
            return {
                name = 'modload',
                server = server,
                module = module,
            }
        end
    end

    do
        local module =
        string.match(str, '^Module ([^ ]+) unloaded$')
        if module then
            return {
                name = 'modunload',
                server = server,
                module = module,
            }
        end
    end

    do
        local nick, user, host, oper, interval, reason =
        string.match(str, '^([^!]+)!([^@]+)@([^{]+){([^}]*)} enabled user shedding %(interval: ([0-9]+) seconds, reason: (.*)%)$')
        if nick then
            return {
                name = 'shedding_on',
                server = server,
                nick = nick,
                user = user,
                host = host,
                oper = oper,
                interval = tonumber(interval),
                reason = reason,
            }
        end
    end

    do
        local nick, user, host, oper =
        string.match(str, '^([^!]+)!([^@]+)@([^{]+){([^}]*)} disabled user shedding$')
        if nick then
            return {
                name = 'shedding_off',
                server = server,
                nick = nick,
                user = user,
                host = host,
                oper = oper,
            }
        end
    end

    do
        local name = simple[str]
        if name then
            return {
                name = name,
                server = server,
            }
        end
    end
end
