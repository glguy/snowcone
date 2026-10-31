-- Find a user's username, host and address for a ban: lookup(t, nick)
-- from a network task, with WHO, then WHOWAS for someone who has left.
--
-- The address is 255.255.255.255 when the server won't say: WHO hides it
-- from all but operators, and WHOWAS gives it only with RPL_WHOISACTUALLY.
-- Raises when the network can't send the WHO.

local irc_model <const> = require 'hub.net.irc'
local N         <const> = require 'hub.lib.numerics'

---@class hub.Lookup
---@field nick string as the server spells it
---@field user string
---@field host string
---@field ip string

---@param t hub.Task
---@param nick string
---@return hub.Lookup|nil
---@return string|nil # why there is no answer
return function(t, nick)
    -- first, so a network without a connection fails with a message
    local who = t:request({N.RPL_WHOSPCRPL, N.RPL_ENDOFWHO}, 30000, 'WHO', nick, '%tuihn,696')

    local irc = HUB.state.nets[t.net].irc
    ---@cast irc -nil the WHO went out, so the network is connected
    local key = irc_model.fold(irc, nick)
    local function same(n) return n and irc_model.fold(irc, n) == key end

    local found_end
    for msg in who do
        if msg.command == N.RPL_WHOSPCRPL and msg[2] == '696' and same(msg[6]) then
            return {nick = msg[6], user = msg[3], host = msg[5], ip = msg[4]}
        elseif msg.command == N.RPL_ENDOFWHO and same(msg[2]) then
            found_end = true
            break
        end
    end
    if not found_end then return nil, 'no WHO reply for ' .. nick end

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
