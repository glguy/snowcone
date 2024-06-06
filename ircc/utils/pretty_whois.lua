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

        local handlers <const> = {
            [N.RPL_WHOISUSER] = function(irc)
                nick, username, host, info = irc[2], irc[3], irc[4], irc[6]
            end,
            [N.RPL_WHOISCHANNELS] = function(irc)
                for channel in irc[3]:gmatch '[^ ]+' do
                    table.insert(channels, channel)
                end
            end,
            [N.RPL_WHOISSERVER] = function(irc)
                server = irc[3]
            end,
            [N.RPL_AWAY] = function(irc)
                away = irc[3]
            end,
            [N.RPL_WHOISOPERATOR] = function(irc)
                operator, privset = irc[3]:match '^is opered as ([^ ]+), privset ([^ ]+)$'
                if not operator then
                    operator = irc[3]:match '^is opered as ([^ ]+)$'
                end
            end,
            [N.RPL_WHOISSECURE] = function()
                secure = true
            end,
            [N.RPL_WHOISCERTFP] = function(irc)
                certfp = irc[3]:match '^has client certificate fingerprint ([^ ]+)$'
            end,
            [N.RPL_WHOISHOST] = function(irc)
                mask, ip = irc[3]:match '^is connecting from ([^ ]+) ([^ ]+)$'
            end,
            [N.RPL_WHOISACTUALLY] = function(irc)
                mask, ip = '*', irc[3]
            end,
            [N.RPL_WHOISSPECIAL] = function(irc)
                table.insert(specials, irc[3])
            end,
            [N.RPL_WHOISIDLE] = function(irc)
                idletime, signontime = irc[3], irc[4]
            end,
            [N.RPL_WHOISLOGGEDIN] = function(irc)
                account = irc[3]
            end,
            [N.RPL_WHOISHELPOP] = function()
                helpop = true
            end,
            [N.RPL_ENDOFWHOIS] = function()
                status('whois', '\x0307╔═╡ \x0303WHOIS\x03: \x02%s\x02!\x02%s\x02@\x02%s\x02 %s',
                    nick, username, host, info)

                if mask then
                    local org, asn = ip_org(ip)
                    status('whois', '\x0307║\x03    mask: \x02%s\x02 ip: \x02%s\x02 asn: \x02%s\x02 org: \x02%s',
                        mask, ip, asn or '*', org or '*')
                end

                if operator then
                    status('whois',
                        '\x0307║\x03 account: \x02%s\x02 operator: \x02%s\x02 privset: \x02%s\x02 helpop: \x02%s',
                        account or '*', operator, privset or '*', helpop)
                elseif helpop then
                    status('whois', '\x0307║\x03 account: \x02%s helpop: \x02%s', account or '*', true)
                else
                    status('whois', '\x0307║\x03 account: \x02%s', account or '*')
                end

                status('whois', '\x0307║\x03  secure: \x02%s\x02 certfp: \x02%s', secure, certfp or '*')

                status('whois', '\x0307║\x03channels: \x02%s', table.concat(channels, ' '))

                if idletime then
                    local now = os.time()
                    status(
                        'whois', '\x0307║\x03    idle: \x02%s\x02 (\x02%s\x02)',
                        os.date('%c', now - idletime),
                        time.pretty_seconds(idletime))
                    status(
                        'whois', '\x0307║\x03  signon: \x02%s\x02 (\x02%s\x02)',
                        os.date('%c', signontime),
                        time.pretty_seconds(os.time() - signontime))
                end

                if away then
                    status('whois', '\x0307║\x03    away: %s', away)
                end

                for _, special in ipairs(specials) do
                    status('whois', '\x0307║\x03 special: \x02%s', special)
                end

                status('whois', '\x0307╚═\x03 server: \x02%s', server)

                return true
            end,

            [N.ERR_NOSUCHSERVER] = function()
                status('whois', 'whois failed: no such server')
                return true
            end,
            [N.ERR_NONICKNAMEGIVEN] = function()
                status('whois', 'whois failed: no nickname given')
                return true
            end,
            [N.ERR_NOSUCHNICK] = function()
                status('whois', 'whois failed: no such nickname')
                return true
            end,
        }

        while true do
            local irc = task:wait_irc(handlers)
            if snowcone.irccase(irc[2]) == snowcone.irccase(nick)
            and handlers[irc.command](irc) then
                break
            end
        end
    end)
end
