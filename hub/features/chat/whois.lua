-- A WHOIS summarized in the status log, run as a network task:
-- whois(t, nick, remote).

local ip_org    <const> = require 'hub.features.snotice.ip_org'
local irc_model <const> = require 'hub.net.irc'
local N         <const> = require 'hub.lib.numerics'

local function pretty_seconds(s)
    s = math.tointeger(tonumber(s)) or 0
    local d, h, m = s // 86400, s % 86400 // 3600, s % 3600 // 60
    if d > 0 then return string.format('%dd %dh %dm', d, h, m) end
    if h > 0 then return string.format('%dh %dm', h, m) end
    if m > 0 then return string.format('%dm %ds', m, s % 60) end
    return s .. 's'
end

return function(t, nick, remote)
    local username, host, info
    local channels = {}
    local server, away, operator, privset, certfp, mask, ip
    local helpop, secure = false, false
    local specials = {}
    local idletime, signontime, account

    local function out(fmt, ...)
        t:log('whois', fmt, ...)
    end

    local handlers <const> = {
        [N.RPL_WHOISUSER] = function(msg)
            nick, username, host, info = msg[2], msg[3], msg[4], msg[6]
        end,
        [N.RPL_WHOISCHANNELS] = function(msg)
            for channel in (msg[3] or ''):gmatch '[^ ]+' do
                table.insert(channels, channel)
            end
        end,
        [N.RPL_WHOISSERVER] = function(msg) server = msg[3] end,
        [N.RPL_AWAY] = function(msg) away = msg[3] end,
        [N.RPL_WHOISOPERATOR] = function(msg)
            operator, privset = (msg[3] or ''):match '^is opered as ([^ ]+), privset ([^ ]+)$'
            if not operator then
                operator = (msg[3] or ''):match '^is opered as ([^ ]+)$'
            end
        end,
        [N.RPL_WHOISSECURE] = function() secure = true end,
        [N.RPL_WHOISCERTFP] = function(msg)
            certfp = (msg[3] or ''):match '^has client certificate fingerprint ([^ ]+)$'
        end,
        [N.RPL_WHOISHOST] = function(msg)
            mask, ip = (msg[3] or ''):match '^is connecting from ([^ ]+) ([^ ]+)$'
        end,
        [N.RPL_WHOISACTUALLY] = function(msg) mask, ip = '*', msg[3] end,
        [N.RPL_WHOISSPECIAL] = function(msg) table.insert(specials, msg[3]) end,
        [N.RPL_WHOISIDLE] = function(msg) idletime, signontime = msg[3], msg[4] end,
        [N.RPL_WHOISLOGGEDIN] = function(msg) account = msg[3] end,
        [N.RPL_WHOISHELPOP] = function() helpop = true end,
        [N.RPL_ENDOFWHOIS] = function()
            out('\x0307╓   \x0303WHOIS\x03: \x02%s\x02!\x02%s\x02@\x02%s\x02 %s',
                nick, username or '?', host or '?', info or '')
            if mask then
                local org, asn = ip_org.lookup(ip)
                out('\x0307║\x03    mask: \x02%s\x02 ip: \x02%s\x02 asn: \x02%s\x02 org: \x02%s',
                    mask, ip or '*', asn or '*', org or '*')
            end
            if operator then
                out('\x0307║\x03 account: \x02%s\x02 operator: \x02%s\x02 privset: \x02%s\x02 helpop: \x02%s',
                    account or '*', operator, privset or '*', helpop)
            elseif helpop then
                out('\x0307║\x03 account: \x02%s helpop: \x02%s', account or '*', true)
            else
                out('\x0307║\x03 account: \x02%s', account or '*')
            end
            out('\x0307║\x03  secure: \x02%s\x02 certfp: \x02%s', secure, certfp or '*')
            out('\x0307║\x03channels: \x02%s', table.concat(channels, ' '))
            if idletime then
                local now = os.time()
                out('\x0307║\x03    idle: \x02%s\x02 (\x02%s\x02)',
                    os.date('%c', now - (tonumber(idletime) or 0)), pretty_seconds(idletime))
                out('\x0307║\x03  signon: \x02%s\x02 (\x02%s\x02)',
                    os.date('%c', tonumber(signontime) or 0), pretty_seconds(now - (tonumber(signontime) or now)))
            end
            if away then
                out('\x0307║\x03    away: %s', away)
            end
            for _, special in ipairs(specials) do
                out('\x0307║\x03 special: \x02%s', special)
            end
            out('\x0307╙ \x03 server: \x02%s', server or '?')
            return true
        end,
        [N.ERR_NOSUCHSERVER] = function() out('whois failed: no such server') return true end,
        [N.ERR_NONICKNAMEGIVEN] = function() out('whois failed: no nickname given') return true end,
        [N.ERR_NOSUCHNICK] = function() out('whois failed: no such nickname') return true end,
    }

    local commands = {}
    for k in pairs(handlers) do commands[k] = true end

    local replies
    if remote then
        replies = t:request(commands, 30000, 'WHOIS', nick, nick)
    else
        replies = t:request(commands, 30000, 'WHOIS', nick)
    end

    local irc = HUB.state.nets[t.net].irc
    ---@cast irc -nil the WHOIS went out, so the network is connected
    local key = irc_model.fold(irc, nick)
    for msg in replies do
        if msg[2] and irc_model.fold(irc, msg[2]) == key and handlers[msg.command](msg) then
            return
        end
    end
    out('whois %s: no reply', nick)
end
