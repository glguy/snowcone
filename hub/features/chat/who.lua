-- A WHO run as a network task: who(t, mask, options). The users it lists
-- are gathered into a hub.Who, logged as one line that opens it, and
-- emitted as chat.who for the UI to show.
--
-- options is WHO's second argument as typed: an o first lists only
-- operators, and a % starts a WHOX format, its field letters then an
-- optional ,token. With a format the server replies with 354, giving
-- only the fields asked for, always in the order t c u i h s n f d l a o
-- r whatever order they were asked in; without one, with 352, giving
-- channel, user, host, server, nick, status, hops and realname. Each
-- reply is read by its numeric, whatever was asked.
--
-- A server without WHOX (OFTC hybrid) reads WHO its own way: the command
-- sends it no format and no +flags search, and its o lists only
-- operators with the mask 0 alone.
--
-- The status is H (here) or G (gone, away), then the bot mode's letter
-- (ISUPPORT BOT) for a bot, * for an operator, and the channel prefixes
-- held in the reply's channel. An operator's !mask is an operspy WHO.
--
-- The WHO ends at the RPL_ENDOFWHO naming its mask as the server spells
-- it: as sent, or without the ! of an operspy WHO, with runs of *
-- collapsed or not; * for the masks * and 0. A server without WHOX
-- answers a channel that doesn't exist with ERR_NOSUCHCHANNEL and no end.
--
-- Without labeled-response the replies of every WHO pending arrive mixed,
-- but in the order the WHOs went out: the rows before another WHO's end
-- are its rows, and are dropped; the token, when the format asks for it,
-- tells our 354s from others.
--
-- A server stops at a limit for a user who isn't an operator: Solanum
-- sends ERR_TOOMANYMATCHES before the end, and OFTC hybrid
-- ERR_WHOLIMEXCEED, and the WHO is marked truncated. RPL_LOAD2HI doesn't say which WHO it
-- refuses, so one fails every WHO pending.

local bus       <const> = require 'hub.runtime.bus'
local ip_org    <const> = require 'hub.features.ip_org'
local irc_model <const> = require 'hub.net.irc'
local log       <const> = require 'hub.runtime.log'
local N         <const> = require 'hub.lib.numerics'
local NH        <const> = require 'hub.lib.numerics_hybrid'

--- One user a WHO lists. Each field is nil when the reply didn't give it,
--- or gave its "none": channel *, ip 255.255.255.255, account 0.
---@class hub.WhoRow
---@field channel string|nil a channel the user is in that we may see
---@field user string|nil
---@field ip string|nil the real address, for an operator asking
---@field host string|nil
---@field server string|nil
---@field nick string|nil
---@field status string|nil as the server sent it
---@field hops integer|nil
---@field idle integer|nil seconds, 0 for a user on another server
---@field account string|nil
---@field oplevel string|nil 999 for a channel operator, n/a otherwise
---@field realname string|nil
---@field away boolean|nil from the status, when it was given
---@field bot boolean|nil
---@field oper boolean|nil
---@field prefixes string|nil channel prefixes, highest first
---@field asn integer|nil
---@field org string|nil

--- A WHO reply, in the server's order.
---@class hub.Who
---@field mask string as sent
---@field options string|nil the second argument, as sent
---@field opers_only boolean
---@field fields string[] the letters the replies give, in their order
---@field token string|nil the WHOX token, when the format asks for it
---@field rows hub.WhoRow[]
---@field truncated boolean the server stopped at its limit of matches
---@field at integer epoch seconds when the reply came

--- WHOX field letters in the order a 354 gives them, and their names in
--- a hub.WhoRow.
local whox_order <const> = {'t', 'c', 'u', 'i', 'h', 's', 'n', 'f', 'd', 'l', 'a', 'o', 'r'}
local whox_names <const> = {
    t = 'token', c = 'channel', u = 'user', i = 'ip', h = 'host', s = 'server', n = 'nick',
    f = 'status', d = 'hops', l = 'idle', a = 'account', o = 'oplevel', r = 'realname',
}

--- The fields of a 352.
local plain_fields <const> = {'c', 'u', 'h', 's', 'n', 'f', 'd', 'r'}

local M = {}

M.whox_order = whox_order
M.whox_names = whox_names

--- Read WHO's second argument as Solanum does: whether only operators are
--- asked for, the WHOX fields in reply order (nil for no format), and the
--- token, which is 0 when missing or longer than three characters.
---@param options string|nil
---@return boolean opers_only
---@return string[]|nil fields
---@return string|nil token
function M.parse_options(options)
    if not options or options == '' then return false, nil, nil end
    local opers_only = options:sub(1, 1) == 'o'
    local format = options:match '%%(.*)$'
    if not format then return opers_only, nil, nil end
    local letters, token = format:match '^([^,]*),?(.*)$'
    local asked = {}
    for letter in letters:gmatch '.' do asked[letter] = true end
    local fields = {}
    for _, letter in ipairs(whox_order) do
        if asked[letter] then table.insert(fields, letter) end
    end
    if #fields == 0 then return opers_only, nil, nil end
    if token == '' or #token > 3 then token = '0' end
    return opers_only, fields, asked.t and token or nil
end

--- Decode a status into away, bot, oper and the channel prefixes.
---@param irc hub.Irc
---@param row hub.WhoRow
local function decode_status(irc, row)
    local status = row.status
    if not status then return end
    row.away = status:sub(1, 1) == 'G'
    local bot_letter = irc.isupport.BOT
    if type(bot_letter) ~= 'string' or #bot_letter ~= 1 then bot_letter = nil end
    local prefixes = {}
    for c in status:sub(2):gmatch '.' do
        if c == bot_letter then
            row.bot = true
        elseif c == '*' then
            row.oper = true
        elseif irc.prefixes:find(c, 1, true) then
            table.insert(prefixes, c)
        end
    end
    row.bot, row.oper = row.bot or false, row.oper or false
    row.prefixes = table.concat(prefixes)
end

--- Clear the values a reply uses for "none".
---@param row hub.WhoRow
local function clear_nones(row)
    if row.channel == '*' then row.channel = nil end
    if row.ip == '255.255.255.255' then row.ip = nil end
    if row.account == '0' then row.account = nil end
end

---@param t hub.Task
---@param mask string
---@param options string|nil
function M.run(t, mask, options)
    local irc = HUB.state.nets[t.net] and HUB.state.nets[t.net].irc
    -- a network without a connection fails with a message from the send
    local opers_only, whox, token = M.parse_options(options)
    if irc and not irc.isupport.WHOX then opers_only = opers_only and mask == '0' end
    ---@type hub.Who
    local w = {mask = mask, options = options, opers_only = opers_only, fields = whox or plain_fields,
        token = token, rows = {}, truncated = false, at = os.time()}

    local function fail(fmt, ...)
        t:log('who', fmt, ...)
    end

    local ends = {}
    if irc then
        for _, name in ipairs {mask, mask:match '^!(.+)$'} do
            ends[irc_model.fold(irc, name)] = true
            ends[irc_model.fold(irc, (name:gsub('%*+', '*')))] = true
        end
        if mask == '0' then ends['*'] = true end
    end

    local handlers <const> = {
        -- "<client> <channel> <user> <host> <server> <nick> <status> :<hops> <realname>"
        [N.RPL_WHOREPLY] = function(msg)
            w.fields = plain_fields
            local hops, realname = (msg[8] or ''):match '^(%d+) ?(.*)$'
            local row = {channel = msg[2], user = msg[3], host = msg[4], server = msg[5], nick = msg[6],
                status = msg[7], hops = math.tointeger(tonumber(hops)), realname = realname or msg[8]}
            table.insert(w.rows, row)
        end,
        -- "<client> [token] [channel] [user] ... [:realname]", the fields
        -- asked for
        [N.RPL_WHOSPCRPL] = function(msg)
            if not whox then return end
            if token and msg[2] ~= token then return end -- another WHO's
            local row = {}
            for i, letter in ipairs(whox) do
                row[whox_names[letter]] = msg[i + 1]
            end
            row.token = nil
            row.hops = row.hops and math.tointeger(tonumber(row.hops))
            row.idle = row.idle and math.tointeger(tonumber(row.idle))
            table.insert(w.rows, row)
        end,
        [N.RPL_ENDOFWHO] = function(msg)
            if not ends[irc_model.fold(irc, msg[2] or '')] then
                w.rows, w.truncated = {}, false -- another WHO's
                return
            end
            for _, row in ipairs(w.rows) do
                clear_nones(row)
                decode_status(irc, row)
                if row.ip then row.org, row.asn = ip_org.lookup(row.ip) end
            end
            local n = #w.rows
            log.add_detail(t.net, 'who', {kind = 'who', data = w}, 'who %s%s: %d %s%s%s', mask,
                options and options ~= '' and ' ' .. options or '', n, n == 1 and 'user' or 'users',
                opers_only and ' (operators only)' or '', w.truncated and ', truncated' or '')
            bus.emit('chat.who', {net = t.net, who = w})
            return true
        end,
        -- "<client> WHO :output too large, truncated" (Solanum) and
        -- "<client> <limit> :WHO search limit exceeded." (OFTC hybrid)
        [N.ERR_TOOMANYMATCHES] = function(msg)
            if msg[2] == 'WHO' then w.truncated = true end
        end,
        [NH.ERR_WHOLIMEXCEED] = function() w.truncated = true end,
        -- "<client> <channel> :No such channel"
        [N.ERR_NOSUCHCHANNEL] = function(msg)
            if ends[irc_model.fold(irc, msg[2] or '')] then
                fail('who %s: no such channel', mask)
                return true
            end
        end,
    }

    local commands = {[N.RPL_LOAD2HI] = true}
    for k in pairs(handlers) do commands[k] = true end

    local replies
    if options and options ~= '' then
        replies = t:request(commands, 30000, 'WHO', mask, options)
    else
        replies = t:request(commands, 30000, 'WHO', mask)
    end
    ---@cast irc -nil the WHO went out, so the network is connected

    for msg in replies do
        -- "<client> <command> :Server load is temporarily too heavy..."
        if msg.command == N.RPL_LOAD2HI then
            if msg[2] == 'WHO' then
                return fail('who %s failed: %s', mask, msg[3] or 'try again later')
            end
        elseif handlers[msg.command](msg) then
            return
        end
    end
    fail('who %s: no reply', mask)
end

return M
