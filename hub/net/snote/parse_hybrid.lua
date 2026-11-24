-- Server notice parser for OFTC hybrid. Like parse_solanum.lua,
-- parse(server, text) returns a flat record with `name` and the notice's
-- fields, or nil; records of the same name have the same fields, so the
-- stores and views take either. The caller stamps the time.
--
-- Opers appear as nick!user@host{oper}, clients as nick[user@host]. An
-- address hybrid hides shows as 255.255.255.255.

local ban_names <const> = {
    ['K-Line'] = 'kline',
    ['D-Line'] = 'dline',
    ['X-Line'] = 'xline',
}

local function address(ip)
    if ip ~= '255.255.255.255' and ip ~= '0' then return ip end
end

-- luacheck: ignore 631
return function(server, str)
    do
        local nick, user, host, ip, class, gecos =
            string.match(str, '^Client connecting: (%S+) %(([^@ ]+)@([^) ]+)%) %[(%S*)%] {(%S*)} %[(.*)%]$')
        if nick then
            return {
                name = 'connect',
                server = server,
                nick = nick,
                user = user,
                host = host,
                ip = address(ip),
                gecos = gecos,
                class = class,
            }
        end
    end

    do
        local nick, user, host, reason, ip =
            string.match(str, '^Client exiting: (%S+) %(([^@ ]+)@([^) ]+)%) %[(.*)%] %[(%S*)%]$')
        if nick then
            return {
                name = 'disconnect',
                server = server,
                nick = nick,
                user = user,
                host = host,
                reason = reason,
                ip = address(ip),
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

    -- "<oper> added temporary <n> min. K-Line for [<mask>] [<reason>]",
    -- and without "temporary <n> min." when permanent
    do
        local nick, user, host, oper, rest =
            string.match(str, '^([^! ]+)!([^@ ]+)@([^{ ]+){([^}]*)} added (.*)$')
        if nick then
            local duration, kind, mask, reason =
                string.match(rest, '^temporary (%d+) min%. (%S+) for %[(.-)%] %[(.*)%]$')
            if not duration then
                kind, mask, reason = string.match(rest, '^(%S+) for %[(.-)%] %[(.*)%]$')
            end
            local ban = ban_names[kind]
            if ban then
                return {
                    name = ban,
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
    end

    -- "<oper> has placed a [<n> minute ]local RESV on channel: <name> [<reason>]",
    -- and "on nick <name> : [<reason>]"
    do
        local nick, user, host, oper, rest =
            string.match(str, '^([^! ]+)!([^@ ]+)@([^{ ]+){([^}]*)} has placed a (.*)$')
        if nick then
            local duration, mask, reason =
                string.match(rest, '^(%d+) minute %S+ RESV on %a+:? (%S+) :?%s?%[(.*)%]$')
            if not duration then
                mask, reason = string.match(rest, '^%S+ RESV on %a+:? (%S+) :?%s?%[(.*)%]$')
            end
            if mask then
                return {
                    name = 'resv',
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
    end

    do
        local nick, user, host, oper, kind, mask =
            string.match(str, '^([^! ]+)!([^@ ]+)@([^{ ]+){([^}]*)} has removed the (%S+) for: %[(.*)%]$')
        if not nick then
            nick, user, host, oper, kind, mask =
                string.match(str, '^([^! ]+)!([^@ ]+)@([^{ ]+){([^}]*)} has removed the temporary (%S+) for: %[(.*)%]$')
        end
        if nick then
            return {
                name = 'removed',
                server = server,
                nick = nick,
                user = user,
                host = host,
                oper = oper,
                kind = string.lower(kind), -- k-line, d-line, x-line
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
                kind = string.lower(kind), -- k-line, d-line, x-line, resv
                mask = mask,
            }
        end
    end

    -- "KLINE <user>@<host> (<reason>) active for <nick>[<user>@<ip>]"
    do
        local kind, mask, nick, user, host =
            string.match(str, '^(%u)LINE (%S+) %(.*%) active for (%S+)%[([^@ %[]+)@([^%] ]+)%]$')
        if kind == 'K' then
            return {
                name = 'kline_active',
                server = server,
                nick = nick,
                user = user,
                host = host,
                mask = mask,
            }
        elseif kind == 'D' then
            return {
                name = 'dline_active',
                server = server,
                nick = nick,
                user = user,
                host = host,
                mask = mask:match '@(.*)$' or mask, -- the D-Line's address
            }
        end
    end

    do
        local mask, nick, user, host, ip =
            string.match(str, '^X%-line Rejecting %[(.*)%] %[.*%], user (%S+)%[([^@ %[]+)@([^%] ]+)%] %[(%S*)%]$')
        if nick then
            return {
                name = 'rejected',
                server = server,
                nick = nick,
                user = user,
                host = host,
                mask = mask,
                ip = address(ip),
                kind = 'x-line',
            }
        end
    end

    do
        local nick, from, reason =
            string.match(str, '^Received KILL message for ([^. ]+)%. From (%S+) Path: %S+ %((.*)%)$')
        if not nick then -- by an oper: the path is server!host!user!nick
            nick, from, reason =
                string.match(str, '^Received KILL message for ([^. ]+)%. From (%S+) Path: %S+ (.*)$')
        end
        if not nick then
            nick, from, reason =
                string.match(str, '^Received KILL message for ([^. ]+)%. From (%S+) (.*)$')
        end
        if nick then
            return {
                name = 'kill',
                server = server,
                nick = nick,
                from = from,
                reason = reason,
            }
        end
    end

    -- a split and a join are reported by the server on the near side of
    -- the link, whether an oper dropped it or it was lost; neither gives
    -- server IDs or counts
    do
        local server2 = string.match(str, '^(%S+) was connected for %d+ seconds%.  %d+/%d+ sendK/recvK%.$')
        if server2 then
            return {
                name = 'netsplit',
                server = server,
                server1 = server,
                server2 = server2,
            }
        end
    end

    do
        local server2 = string.match(str, '^Link with ([^[ ]+)%S* established: %(.*%) link$')
        if server2 then
            return {
                name = 'netjoin',
                server = server,
                server1 = server,
                server2 = server2,
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
            string.match(str, '^Possible Flooder (%S+)%[([^@ %[]+)@([^%] ]+)%] on %S+ target: (%S+)$')
        if not nick then
            nick, user, host, target =
                string.match(str, '^Possible Join Flooder (%S+)%[([^@ %[]+)@([^%] ]+)%] on %S+ target: (%S+)$')
        end
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
        local nick, user, host, oper =
            string.match(str, '^(%S+) %(([^@ ]*)@(%S*)%) is now an operator %((.*)%)$')
        if nick then
            return {
                name = 'oper',
                server = server,
                nick = nick,
                user = user,
                host = host,
                oper = oper,
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

    -- "Too many connections from IP (number_per_ip) <nick>[<user>@<ip>] [<ip>] {<class>}",
    -- one per limit, with the limit's setting as the kind
    do
        local kind, nick, user, host, ip, class =
            string.match(str, '^Too many .- %((%S+)%) (%S+)%[([^@ %[]+)@([^%] ]+)%] %[(%S*)%] {(%S*)}$')
        if not kind then
            nick, user, host, ip =
                string.match(str, '^Too many on IP for (%S+)%[([^@ %[]+)@([^%] ]+)%] %((%S*)%)%. %(generic too_many%)$')
            kind = nick and 'too_many'
        end
        if nick then
            return {
                name = 'toomany',
                server = server,
                nick = nick,
                user = user,
                host = host,
                kind = kind,
                ip = address(ip),
                class = class,
            }
        end
    end

    do
        local module = string.match(str, '^Module ([^ ]+) %[.*%] loaded at [^ ]+$')
        if module then
            return {
                name = 'modload',
                server = server,
                module = module,
            }
        end
    end

    do
        local module = string.match(str, '^Module ([^ ]+) unloaded$')
        if module then
            return {
                name = 'modunload',
                server = server,
                module = module,
            }
        end
    end

    do
        local nick, user, host, interval, reason =
            string.match(str, '^User shedding ENABLED by (%S+) %(([^@ ]+)@(%S+)%); interval: (%d+) seconds, opers: %a+, reason: "(.*)"$')
        if nick then
            return {
                name = 'shedding_on',
                server = server,
                nick = nick,
                user = user,
                host = host,
                oper = nick,
                interval = tonumber(interval),
                reason = reason,
            }
        end
    end

    do
        local nick, user, host =
            string.match(str, '^User shedding DISABLED by (%S+) %(([^@ ]+)@(%S+)%)$')
        if nick then
            return {
                name = 'shedding_off',
                server = server,
                nick = nick,
                user = user,
                host = host,
                oper = nick,
            }
        end
    end
end
