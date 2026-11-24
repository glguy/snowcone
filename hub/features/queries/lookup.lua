-- Find a user's username, host and address for a ban: lookup(t, nick)
-- from a network task, with WHO, then WHOWAS for someone who has left.
-- OFTC hybrid has no WHOX, so there WHOIS stands in for WHO: its
-- RPL_WHOISACTUALLY gives operators the address.
--
-- The address is 255.255.255.255 when the server won't say: WHO hides it
-- from all but operators, and WHOWAS gives it only with RPL_WHOISACTUALLY.
-- Raises when the network can't send the WHO.

local irc_model <const> = require 'hub.net.irc'
local ircd      <const> = require 'hub.net.ircd'
local N         <const> = require 'hub.lib.numerics'

---@class hub.Lookup
---@field nick string as the server spells it
---@field user string
---@field host string
---@field ip string

-- The user while connected: true when the server says they aren't, nil
-- when it doesn't answer
---@param t hub.Task
---@param nick string
---@param same fun(n: string|nil): boolean|nil
---@return hub.Lookup|true|nil
local function who(t, nick, same)
    for msg in t:request({N.RPL_WHOSPCRPL, N.RPL_ENDOFWHO}, 30000, 'WHO', nick, '%tuihn,696') do
        if msg.command == N.RPL_WHOSPCRPL and msg[2] == '696' and same(msg[6]) then
            return {nick = msg[6], user = msg[3], host = msg[5], ip = msg[4]}
        elseif msg.command == N.RPL_ENDOFWHO and same(msg[2]) then
            return true
        end
    end
end

---@param t hub.Task
---@param nick string
---@param same fun(n: string|nil): boolean|nil
---@return hub.Lookup|true|nil
local function whois(t, nick, same)
    local found
    for msg in t:request({N.RPL_WHOISUSER, N.RPL_WHOISACTUALLY, N.ERR_NOSUCHNICK, N.RPL_ENDOFWHOIS},
        30000, 'WHOIS', nick)
    do
        local command = msg.command
        if command == N.RPL_WHOISUSER and same(msg[2]) then
            -- "<client> <nick> <username> <host> * :<realname>"
            found = {nick = msg[2], user = msg[3], host = msg[4], ip = '255.255.255.255'}
        elseif command == N.RPL_WHOISACTUALLY and found and same(msg[2]) then
            -- "<client> <nick> <address> :actually using host"
            found.ip = msg[3]
        elseif command == N.ERR_NOSUCHNICK and same(msg[2]) then
            return true
        elseif command == N.RPL_ENDOFWHOIS and same(msg[2]) then
            return found or true
        end
    end
end

---@param t hub.Task
---@param nick string
---@return hub.Lookup|nil
---@return string|nil # why there is no answer
return function(t, nick)
    local irc = HUB.state.nets[t.net] and HUB.state.nets[t.net].irc
    -- a network without a connection fails with a message from the send
    local key = irc and irc_model.fold(irc, nick)
    local function same(n) return n and irc and irc_model.fold(irc, n) == key end

    local online = (ircd.hybrid(t.net) and whois or who)(t, nick, same)
    if type(online) == 'table' then return online end
    if not online then return nil, 'no WHO reply for ' .. nick end

    local user, host, gecos
    for msg in t:request({N.RPL_WHOWASUSER, N.ERR_WASNOSUCHNICK, N.RPL_ENDOFWHOWAS, N.RPL_WHOISACTUALLY},
        30000, 'WHOWAS', nick, '1')
    do
        local command = msg.command
        if command == N.RPL_WHOWASUSER and same(msg[2]) then
            -- "<client> <nick> <username> <host> * :<realname>"
            user, host, gecos = msg[3], msg[4], msg[6]
        elseif command == N.ERR_WASNOSUCHNICK and same(msg[2]) then
            return nil, 'Failed to find ' .. msg[2]
        elseif command == N.RPL_ENDOFWHOWAS and same(msg[2]) then
            if user and host and gecos then
                return {nick = msg[2], user = user, host = host, ip = '255.255.255.255'}
            end
            return nil, 'Failed to find ' .. msg[2]
        elseif command == N.RPL_WHOISACTUALLY and same(msg[2]) then
            if user and host and gecos then
                return {nick = msg[2], user = user, host = host, ip = msg[3]}
            end
            return nil, 'Missing 314 response for ' .. msg[2]
        end
    end
    return nil, 'no WHOWAS reply for ' .. nick
end
