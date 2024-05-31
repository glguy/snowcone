local Task = require 'components.Task'
local N = require 'utils.numerics'
local send = require 'utils.send'
local time = require 'utils.time'
local ip_org = require 'utils.ip_org'

return function(nick, remote)
    Task('whois', irc_state.tasks, function(task)
        if remote then
            send('WHOIS', nick, nick)
        else
            send('WHOIS', nick)
        end

        local username, host, info
        local channels = {}
        local server
        local away
        local operator, privset
        local helpop = false
        local secure = false
        local certfp
        local mask, ip
        local specials = {}
        local idletime, signontime
        local account

        local handlers = {
            [N.RPL_WHOISUSER] = function(irc)
                nick, username, host, info = irc[2], irc[3], irc[4], irc[6]
                return true
            end,
            [N.RPL_WHOISCHANNELS] = function(irc)
                for channel in irc[3]:gmatch '[^ ]+' do
                    table.insert(channels, channel)
                end
                return true
            end,
            [N.RPL_WHOISSERVER] = function(irc)
                server = irc[3]
                return true
            end,
            [N.RPL_AWAY] = function(irc)
                away = irc[3]
                return true
            end,
            [N.RPL_WHOISOPERATOR] = function(irc)
                operator, privset = irc[3]:match '^is opered as ([^ ]+), privset ([^ ]+)$'
                if not operator then
                    operator = irc[3]:match '^is opered as ([^ ]+)$'
                    privset = '*'
                end
                return true
            end,
            [N.RPL_WHOISSECURE] = function()
                secure = true
                return true
            end,
            [N.RPL_WHOISCERTFP] = function(irc)
                certfp = irc[3]:match '^has client certificate fingerprint ([^ ]+)$'
                return true
            end,
            [N.RPL_WHOISHOST] = function(irc)
                mask, ip = irc[3]:match '^is connecting from ([^ ]+) ([^ ]+)$'
                return true
            end,
            [N.RPL_WHOISACTUALLY] = function(irc)
                mask, ip = '*', irc[3]
                return true
            end,
            [N.RPL_WHOISSPECIAL] = function(irc)
                table.insert(specials, irc[3])
                return true
            end,
            [N.RPL_WHOISIDLE] = function(irc)
                idletime, signontime = irc[3], irc[4]
                return true
            end,
            [N.RPL_WHOISLOGGEDIN] = function(irc)
                account = irc[3]
                return true
            end,
            [N.RPL_WHOISHELPOP] = function()
                helpop = true
                return true
            end,
            [N.RPL_ENDOFWHOIS] = function()
                status('whois', '\x0304WHOIS\x03 \x02%s\x02!\x02%s\x02@\x02%s\x02 %s', nick, username, host, info)
                status('whois', 'channels: \x02%s', table.concat(channels, ' '))
                status('whois', 'server: \x02%s', server)
                if away then
                    status('whois', 'away: %s', away)
                end
                if operator then
                    status('whois', 'operator: \x02%s\x02 privset: \x02%s', operator, privset)
                end
                if helpop then
                    status('whois', 'set helpop (+h)')
                end
                status('whois', 'secure: \x02%s\x02 certfp: \x02%s', secure, certfp or '*')
                if mask then
                    local org, asn = ip_org(ip)
                    if org then
                        status('whois', 'mask: \x02%s\x02 ip: \x02%s\x02 asn: \x02%s\x02 org: \x02%s',
                            mask, ip, asn, org)
                    else
                        status('whois', 'mask: \x02%s\x02 ip: \x02%s', mask, ip)
                    end
                end
                local now = os.time()
                status(
                    'whois', 'idle:   \x02%s\x02 (\x02%s\x02)',
                    os.date('%c', now - idletime),
                    time.pretty_seconds(idletime))

                status(
                    'whois', 'signon: \x02%s\x02 (\x02%s\x02)',
                    os.date('%c', signontime),
                    time.pretty_seconds(os.time() - signontime))
                if account then
                    status('whois', 'account: \x02%s', account)
                else
                    status('whois', 'not identified to services')
                end
                for _, special in ipairs(specials) do
                    status('whois', 'special: \x02%s', special)
                end
                return false
            end,

            [N.ERR_NOSUCHSERVER] = function()
                status('whois', 'whois failed: no such server')
                return false
            end,
            [N.ERR_NONICKNAMEGIVEN] = function()
                status('whois', 'whois failed: no nickname given')
                return false
            end,
            [N.ERR_NOSUCHNICK] = function()
                status('whois', 'whois failed: no such nickname')
                return false
            end,
        }

        local active = true
        while active do
            local irc = task:wait_irc(handlers)
            if snowcone.irccase(irc[2]) == snowcone.irccase(nick) then
                active = handlers[irc.command](irc)
            end
        end
    end)
end
