-- A WHOWAS run as a network task: whowas(t, nick). Every past entry the
-- server keeps is gathered into a hub.Whowas, logged as one line that
-- opens it, and emitted as chat.whowas for the UI to show.

local bus       <const> = require 'hub.runtime.bus'
local ip_org    <const> = require 'hub.features.snotice.ip_org'
local irc_model <const> = require 'hub.net.irc'
local log       <const> = require 'hub.runtime.log'
local N         <const> = require 'hub.lib.numerics'

--- One past use of a nick. Text is as the server sent it.
---@class hub.WhowasEntry
---@field nick string
---@field user string|nil
---@field host string|nil
---@field gecos string|nil
---@field server string|nil
---@field signoff string|nil when it left, in the server's words
---@field account string|nil
---@field ip string|nil the real address, for an operator asking
---@field asn integer|nil
---@field org string|nil

--- A WHOWAS reply, newest entry first, as the server lists them.
---@class hub.Whowas
---@field nick string
---@field entries hub.WhowasEntry[]
---@field at integer epoch seconds when the reply came

return function(t, nick)
    ---@type hub.Whowas
    local w = {nick = nick, entries = {}, at = os.time()}
    local entry -- the one the replies after a 314 describe

    local function fail(fmt, ...)
        t:log('whowas', fmt, ...)
    end

    local handlers <const> = {
        -- "<client> <nick> <username> <host> * :<realname>" starts an entry
        [N.RPL_WHOWASUSER] = function(msg)
            entry = {nick = msg[2], user = msg[3], host = msg[4], gecos = msg[6]}
            table.insert(w.entries, entry)
        end,
        -- "<client> <nick> <server> :<signoff time>"
        [N.RPL_WHOISSERVER] = function(msg)
            if entry then entry.server, entry.signoff = msg[3], msg[4] end
        end,
        [N.RPL_WHOISLOGGEDIN] = function(msg)
            if entry then entry.account = msg[3] end
        end,
        [N.RPL_WHOISACTUALLY] = function(msg)
            if entry then entry.ip = msg[3] end
        end,
        [N.ERR_WASNOSUCHNICK] = function()
            fail('whowas %s: no such nickname', nick)
            return true
        end,
        [N.RPL_ENDOFWHOWAS] = function()
            if #w.entries == 0 then
                fail('whowas %s: no such nickname', nick)
                return true
            end
            for _, e in ipairs(w.entries) do
                if e.ip then e.org, e.asn = ip_org.lookup(e.ip) end
            end
            local last = w.entries[1]
            log.add_detail(t.net, 'whowas', {kind = 'whowas', data = w}, '%s!%s@%s %s, %d %s',
                last.nick, last.user or '?', last.host or '?', last.signoff or 'signoff unknown',
                #w.entries, #w.entries == 1 and 'entry' or 'entries')
            bus.emit('chat.whowas', {net = t.net, whowas = w})
            return true
        end,
    }

    local commands = {}
    for k in pairs(handlers) do commands[k] = true end
    commands[N.RPL_LOAD2HI] = true

    local replies = t:request(commands, 30000, 'WHOWAS', nick)

    local irc = HUB.state.nets[t.net].irc
    ---@cast irc -nil the WHOWAS went out, so the network is connected
    local key = irc_model.fold(irc, nick)
    for msg in replies do
        if msg.command == N.RPL_LOAD2HI then
            if msg[2] == 'WHOWAS' then
                return fail('whowas %s failed: %s', nick, msg[3] or 'try again later')
            end
        elseif msg[2] and irc_model.fold(irc, msg[2]) == key and handlers[msg.command](msg) then
            return
        end
    end
    fail('whowas %s: no reply', nick)
end
