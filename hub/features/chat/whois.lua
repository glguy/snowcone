-- A WHOIS run as a network task: whois(t, nick, remote). The reply is
-- gathered into a hub.Whois, logged as one line that opens it, and
-- emitted as chat.whois for the UI to show.

local bus       <const> = require 'hub.runtime.bus'
local ip_org    <const> = require 'hub.features.snotice.ip_org'
local irc_model <const> = require 'hub.net.irc'
local log       <const> = require 'hub.runtime.log'
local N         <const> = require 'hub.lib.numerics'

--- A WHOIS reply. Text is as the server sent it.
---@class hub.Whois
---@field nick string
---@field user string|nil
---@field host string|nil
---@field gecos string|nil
---@field server string|nil
---@field server_info string|nil
---@field account string|nil
---@field away string|nil
---@field operator string|nil the oper block's name
---@field privset string|nil
---@field helpop boolean
---@field secure boolean
---@field certfp string|nil
---@field mask string|nil the real host, for an operator asking
---@field ip string|nil
---@field asn integer|nil
---@field org string|nil
---@field channels string[] with their status prefixes
---@field specials string[]
---@field idle integer|nil seconds idle when the reply came
---@field signon integer|nil epoch seconds
---@field at integer epoch seconds when the reply came

return function(t, nick, remote)
    ---@type hub.Whois
    local w = {nick = nick, channels = {}, specials = {}, helpop = false, secure = false, at = os.time()}

    local function fail(fmt, ...)
        t:log('whois', fmt, ...)
    end

    local handlers <const> = {
        [N.RPL_WHOISUSER] = function(msg)
            w.nick, w.user, w.host, w.gecos = msg[2], msg[3], msg[4], msg[6]
        end,
        [N.RPL_WHOISCHANNELS] = function(msg)
            for channel in (msg[3] or ''):gmatch '[^ ]+' do
                table.insert(w.channels, channel)
            end
        end,
        [N.RPL_WHOISSERVER] = function(msg) w.server, w.server_info = msg[3], msg[4] end,
        [N.RPL_AWAY] = function(msg) w.away = msg[3] end,
        [N.RPL_WHOISOPERATOR] = function(msg)
            w.operator, w.privset = (msg[3] or ''):match '^is opered as ([^ ]+), privset ([^ ]+)$'
            if not w.operator then
                w.operator = (msg[3] or ''):match '^is opered as ([^ ]+)$'
            end
        end,
        [N.RPL_WHOISSECURE] = function() w.secure = true end,
        [N.RPL_WHOISCERTFP] = function(msg)
            w.certfp = (msg[3] or ''):match '^has client certificate fingerprint ([^ ]+)$'
        end,
        [N.RPL_WHOISHOST] = function(msg)
            w.mask, w.ip = (msg[3] or ''):match '^is connecting from ([^ ]+) ([^ ]+)$'
        end,
        [N.RPL_WHOISACTUALLY] = function(msg) w.mask, w.ip = '*', msg[3] end,
        [N.RPL_WHOISSPECIAL] = function(msg) table.insert(w.specials, msg[3]) end,
        [N.RPL_WHOISIDLE] = function(msg)
            w.idle, w.signon = math.tointeger(tonumber(msg[3])), math.tointeger(tonumber(msg[4]))
        end,
        [N.RPL_WHOISLOGGEDIN] = function(msg) w.account = msg[3] end,
        [N.RPL_WHOISHELPOP] = function() w.helpop = true end,
        [N.RPL_ENDOFWHOIS] = function()
            if w.ip then
                w.org, w.asn = ip_org.lookup(w.ip)
            end
            local notes = {}
            if w.account then table.insert(notes, 'account ' .. w.account) end
            if w.operator then table.insert(notes, 'oper ' .. w.operator) end
            table.insert(notes, #w.channels == 1 and '1 channel' or #w.channels .. ' channels')
            if w.away then table.insert(notes, 'away') end
            log.add_detail(t.net, 'whois', {kind = 'whois', data = w}, '%s!%s@%s %s',
                w.nick, w.user or '?', w.host or '?', table.concat(notes, ', '))
            bus.emit('chat.whois', {net = t.net, whois = w})
            return true
        end,
        [N.ERR_NOSUCHSERVER] = function() fail 'whois failed: no such server' return true end,
        [N.ERR_NONICKNAMEGIVEN] = function() fail 'whois failed: no nickname given' return true end,
        [N.ERR_NOSUCHNICK] = function() fail 'whois failed: no such nickname' return true end,
    }

    local commands = {}
    for k in pairs(handlers) do commands[k] = true end
    commands[N.RPL_LOAD2HI] = true -- a remote WHOIS refused

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
        -- "<client> <command> :Server load is temporarily too heavy..."
        if msg.command == N.RPL_LOAD2HI then
            if msg[2] == 'WHOIS' then
                return fail('whois %s failed: %s', nick, msg[3] or 'try again later')
            end
        elseif msg[2] and irc_model.fold(irc, msg[2]) == key and handlers[msg.command](msg) then
            return
        end
    end
    fail('whois %s: no reply', nick)
end
