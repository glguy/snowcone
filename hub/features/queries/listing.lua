-- Replies that list things, gathered as a network task into a
-- hub.Listing, logged as one line that opens it, and emitted as
-- query.listing for the UI to show as tables (ui/details/listing.lua):
--
--   M.stats(t, letter, server)   STATS, ending at RPL_ENDOFSTATS for its letter
--   M.trace(t, target)           TRACE, ending at RPL_ENDOFTRACE
--   M.etrace(t, arg)             ETRACE, ending at RPL_ENDOFTRACE
--   M.masktrace(t, mask, gecos)  MASKTRACE, ending at RPL_ENDOFTRACE
--   M.chantrace(t, channel)      CHANTRACE, ending at RPL_ENDOFTRACE
--   M.motd(t, target)            MOTD, ending at RPL_ENDOFMOTD or ERR_NOMOTD
--   M.info(t, target)            INFO, ending at RPL_ENDOFINFO
--   M.help(t, topic)             HELP, ending at RPL_ENDOFHELP or ERR_HELPNOTFOUND
--   M.modlist(t, pattern, server) MODLIST, ending at RPL_ENDOFMODLIST
--   M.lusers(t, server)          LUSERS, ending at RPL_STATSCONN (on hybrid,
--                                which sends it only to opers or when servers
--                                aren't hidden, at RPL_GLOBALUSERS for others)
--   M.privs(t, nick)             PRIVS, ending at its line without "* "
--   M.scan(t, args)              SCAN UMODES, ending at RPL_SCANMATCHED
--
-- An end may be a reply of its own as well (PRIVS's last line, SCAN's
-- count), kept as the others are. PRIVS of someone with nothing to show
-- has no reply at all: with labels an ACK, which shows an empty listing;
-- without, the wait runs out. LUSERS goes without a label: Solanum's
-- handler for an oper batches nothing, so only its first line would be
-- labeled, and it waits for its end as without labeled-response.
--
-- Every reply but the end is kept, in order, except the errors: those
-- that end a reply fail the task (no such server or nick, naming the
-- target; for CHANTRACE, no such channel or not on it, naming the
-- channel; for MOTD, no MOTD, and for HELP, no such topic, which come in
-- place of the end; the command unknown or short of arguments, naming
-- it; no privileges for an oper command, or for MODLIST, which no end
-- follows, the admin privilege; OFTC hybrid's refusal of a STATS for
-- load, which no end follows), and those the server follows with the end
-- (a STATS refused for privileges, load, or as disabled; STATS's short of
-- arguments on hybrid) are kept apart, to show above the tables.
--
-- Without labeled-response the replies of every listing pending arrive
-- mixed, but in the order the commands went out. The listings that end
-- alike (the STATS of a letter; the traces, all with RPL_ENDOFTRACE; the
-- MOTDs; and each other kind's) wait in a queue per network in the order
-- sent, and an end goes to the first that takes it: any, or for a trace of
-- a target or a PRIVS, one naming the nick, or for one of a server, one
-- from it.
-- The rows before an end that isn't a listing's own belong to another,
-- and are dropped, unless they are told by their source or the nick they
-- name.

local bus       <const> = require 'hub.runtime.bus'
local common    <const> = require 'hub.features.common'
local irc_model <const> = require 'hub.net.irc'
local ircd      <const> = require 'hub.net.ircd'
local log       <const> = require 'hub.runtime.log'
local N         <const> = require 'hub.lib.numerics'

--- A listing: what was asked, and the replies.
---@class hub.Listing
---@field kind 'stats'|'trace'|'etrace'|'masktrace'|'chantrace'|'motd'|'info'|'help'|'modlist'|'lusers'|'privs'|'scan'
---@field command string as sent, with its arguments
---@field messages hub.Message[] the replies, in order
---@field errors hub.Message[] errors the server followed with the end
---@field relabel table<string, string>|nil field labels that mean
--- something else in this reply: MASKTRACE and CHANTRACE give each
--- user's server where ETRACE gives the class
---@field lines hub.ListingLines|nil when the replies are lines of text

--- Replies shown as lines of text, in one table: each reply's last
--- argument, less `strip`; with `middle`, after the arguments between our
--- nick and it that it doesn't hold (LUSERS's counts); with `words`, a row
--- for each of its words.
---@class hub.ListingLines
---@field under integer the numeric to show them all under
---@field column string|nil the column's header; default text
---@field strip string|nil a Lua pattern to take off the start
---@field middle boolean|nil
---@field words boolean|nil
---@field at integer epoch seconds when the end came
---@field view table|nil the UI's tables, worked out once (ui/details/listing.lua)

local M = {}

local function range(set, lo, hi)
    for n = lo, hi do set[n] = true end
    return set
end

-- The replies each kind lists
local stats_rows <const> = range({}, 210, 250)
local trace_rows <const> = range({[N.RPL_TRACELOG] = true}, 200, 209)
local etrace_rows <const> = {[N.RPL_ETRACE] = true, [N.RPL_ETRACEFULL] = true}
-- the lines; the start of each only names the server
local motd_rows <const> = {[N.RPL_MOTD] = true}
local info_rows <const> = {[N.RPL_INFO] = true}
-- the first line, then the rest
local help_rows <const> = {[N.RPL_HELPSTART] = true, [N.RPL_HELPTXT] = true}
local modlist_rows <const> = {[N.RPL_MODLIST] = true}
local lusers_rows <const> = range({[N.RPL_LOCALUSERS] = true, [N.RPL_GLOBALUSERS] = true}, 250, 255)
local privs_rows <const> = {[N.RPL_PRIVS] = true}
local scan_rows <const> = {[N.RPL_SCANUMODES] = true, [N.RPL_SCANMATCHED] = true}

-- PRIVS's last line is the one without the "* " that says more follow
local function privs_last(msg)
    return not (msg[#msg] or ''):find '^%* '
end

-- The ends of each kind's queue: true, 'row' for one that is a reply to
-- keep as well, 'fails' for one that says there is nothing to list, or a
-- function of the reply giving one of those or nil for a reply that isn't
-- an end
local stats_ends <const> = {[N.RPL_ENDOFSTATS] = true}
local trace_ends <const> = {[N.RPL_ENDOFTRACE] = true}
local motd_ends <const> = {[N.RPL_ENDOFMOTD] = true, [N.ERR_NOMOTD] = 'fails'}
local info_ends <const> = {[N.RPL_ENDOFINFO] = true}
local help_ends <const> = {[N.RPL_ENDOFHELP] = true, [N.ERR_HELPNOTFOUND] = 'fails'}
local modlist_ends <const> = {[N.RPL_ENDOFMODLIST] = true}
local lusers_ends <const> = {[N.RPL_STATSCONN] = 'row'}
local lusers_ends_hidden <const> = {[N.RPL_GLOBALUSERS] = 'row'}
local privs_ends <const> = {[N.RPL_PRIVS] = function(msg) return privs_last(msg) and 'row' or nil end}
local scan_ends <const> = {[N.RPL_SCANMATCHED] = 'row'}

-- The queue an end belongs to, nil for a message that isn't one
local function end_key(msg)
    local n = msg.command
    if n == N.RPL_ENDOFSTATS then return 'stats ' .. tostring(msg[2]) end
    if n == N.RPL_ENDOFTRACE then return 'trace' end
    if n == N.RPL_ENDOFMOTD or n == N.ERR_NOMOTD then return 'motd' end
    if n == N.RPL_ENDOFINFO then return 'info' end
    if n == N.RPL_ENDOFHELP or n == N.ERR_HELPNOTFOUND then return 'help' end
    if n == N.RPL_ENDOFMODLIST then return 'modlist' end
    if n == N.RPL_STATSCONN or n == N.RPL_GLOBALUSERS then return 'lusers' end
    if n == N.RPL_PRIVS and privs_last(msg) then return 'privs' end
    if n == N.RPL_SCANMATCHED then return 'scan' end
end

-- Unlabeled listings live in the queries state, as a task keeps its code
-- across a reload and must share them with tasks of the new code.

--- An unlabeled listing waiting for its end.
---@class hub.ListingWait
---@field id integer its task
---@field field 'source'|2|nil the field of the end that must name `name`;
--- nil takes any end
---@field name string|nil folded

--- A network's queries, state.features.queries[net].
---@class hub.QueriesState
---@field listings table<string, hub.ListingWait[]> by queue, in the order sent
---@field claim {msg: hub.Message, id: integer|false}|nil the last end and
--- the task it went to, for every task that sees it

---@return hub.QueriesState
local function new_state()
    return {listings = {}}
end

local function get(net)
    return common.net_state('queries', net, new_state)
end

local function queue(net, key)
    local by_key = get(net).listings
    local q = by_key[key]
    if not q then
        q = {}
        by_key[key] = q
    end
    return q
end

local function leave(net, key, id)
    local q = queue(net, key)
    for i, entry in ipairs(q) do
        if entry.id == id then
            table.remove(q, i)
            return
        end
    end
end

-- The task an end goes to: the first in its queue still running that
-- takes it, worked out by the first task to see it; false for none
local function owner(net, irc, msg)
    local S = get(net)
    if S.claim and S.claim.msg == msg then return S.claim.id end
    local q = queue(net, end_key(msg))
    for i = #q, 1, -1 do
        if not HUB.tasks[q[i].id] then table.remove(q, i) end
    end
    local id = false
    for i, entry in ipairs(q) do
        local named = entry.field and msg[entry.field]
        if not entry.field or named and irc_model.fold(irc, named) == entry.name then
            id = entry.id
            table.remove(q, i)
            break
        end
    end
    S.claim = {msg = msg, id = id}
    return id
end

---@param t hub.Task
---@param spec {kind: string, args: string[], target: string|nil, rows: table<integer, true>,
--- ends: table<integer, true|'row'|'fails'|fun(msg: hub.Message): true|'row'|'fails'|nil>, key: string,
--- names: {field: 'source'|2, name: string}|nil, from: (fun(msg: hub.Message): boolean)|nil,
--- relabel: table<string, string>|nil, lines: hub.ListingLines|nil, unended: boolean|nil,
--- timeout_ms: integer|nil, silence: string|nil, unlabeled: boolean|nil}
local function gather(t, spec)
    local command = table.concat(spec.args, ' ')
    ---@type hub.Listing
    local l = {kind = spec.kind, command = command, messages = {}, errors = {}, relabel = spec.relabel,
        lines = spec.lines, at = os.time()}

    local function fail(fmt, ...)
        t:log(spec.kind, fmt, ...)
    end

    local function finish()
        local count = #l.messages
        l.at = os.time()
        log.add_detail(t.net, spec.kind, {kind = 'listing', data = l}, '%s: %d %s%s', command, count,
            count == 1 and 'reply' or 'replies', #l.errors > 0 and ', refused' or '')
        bus.emit('query.listing', {net = t.net, listing = l})
    end

    local first = spec.args[1]
    local irc = HUB.state.nets[t.net] and HUB.state.nets[t.net].irc
    -- a network without a connection fails with a message from the send
    local function is_target(name)
        return irc ~= nil and spec.target ~= nil and name ~= nil
            and irc_model.fold(irc, name) == irc_model.fold(irc, spec.target)
    end
    local function is_command(name) return name ~= nil and name:upper() == first end
    local function any() return true end

    -- errors that end the reply, each when it is about this one, and those
    -- the end follows
    local fatal <const> = {
        [N.ERR_NOSUCHSERVER] = is_target,
        [N.ERR_NOSUCHNICK] = is_target,
        [N.ERR_UNKNOWNCOMMAND] = is_command,
        [N.ERR_NEEDMOREPARAMS] = is_command,
    }
    local noted <const> = {[N.RPL_LOAD2HI] = is_command, [N.ERR_NOPRIVS] = any}
    if spec.kind == 'stats' then
        noted[N.ERR_NOPRIVILEGES] = any
        -- "<client> STATS <letter> :This command has been administratively disabled"
        noted[N.ERR_DISABLED] = function(name) return name ~= nil and name:upper():find '^STATS' ~= nil end
        noted[N.ERR_NEEDMOREPARAMS], fatal[N.ERR_NEEDMOREPARAMS] = is_command, nil
        if ircd.hybrid(t.net) then
            noted[N.RPL_LOAD2HI], fatal[N.RPL_LOAD2HI] = nil, is_command
        end
    elseif spec.kind ~= 'trace' and spec.kind ~= 'motd' and spec.kind ~= 'info' and spec.kind ~= 'lusers' then
        -- the oper commands, and PRIVS of another; TRACE, MOTD, INFO and
        -- LUSERS are anyone's
        fatal[N.ERR_NOPRIVILEGES] = any
    end
    if spec.kind == 'modlist' or spec.kind == 'privs' or spec.kind == 'scan' then
        -- "<client> admin :Insufficient oper privs" (or privs, or
        -- oper_spy), and nothing after
        noted[N.ERR_NOPRIVS], fatal[N.ERR_NOPRIVS] = nil, any
    end
    if spec.kind == 'chantrace' then
        -- "<client> <channel> :No such channel", and the same for one
        -- we aren't on: without the ! for an oper with operspy, with it
        -- for anyone else, who has no ! to strip
        local function is_channel(name)
            return is_target(name) or is_target(name and '!' .. name)
        end
        fatal[N.ERR_NOSUCHCHANNEL] = is_channel
        fatal[N.ERR_NOTONCHANNEL] = is_channel
    end

    -- only the ends of its own queue: another queue's end says nothing of
    -- whose the rows before it are
    local commands = {}
    for set in pairs {[spec.rows] = true, [spec.ends] = true, [fatal] = true, [noted] = true} do
        for k in pairs(set) do commands[k] = true end
    end
    -- a labeled reply with nothing in it
    if spec.unended then commands.ACK = true end

    -- with labels every end in the reply is ours
    local queued = irc ~= nil and (spec.unlabeled or not irc_model.has_labels(irc))
    if queued then
        local names = spec.names
        table.insert(queue(t.net, spec.key), {id = t.id, field = names and names.field, name = names and names.name})
    end
    local function mine(msg)
        if not queued then return end_key(msg) == spec.key end
        return owner(t.net, irc, msg) == t.id
    end

    local function kept(msg)
        return spec.rows[msg.command] and (not spec.from or spec.from(msg))
    end

    -- One reply: true once the listing is done, shown or failed
    local function step(msg)
        local n = msg.command
        local ending = spec.ends[n]
        if type(ending) == 'function' then ending = ending(msg) end
        if ending then
            local own = mine(msg)
            if own and ending == 'fails' then
                -- "<client> :MOTD File is missing", "<client> <topic> :Help not found"
                fail('%s: %s', command, msg[#msg] or 'nothing')
                return true
            elseif own then
                if ending == 'row' and kept(msg) then table.insert(l.messages, msg) end
                finish()
                return true
            elseif queued and not spec.from then
                -- another listing's: what came before it was its own, but
                -- for rows told apart by what they name
                l.messages, l.errors = {}, {}
            end
        elseif fatal[n] and fatal[n](msg[2]) then
            if queued then leave(t.net, spec.key, t.id) end
            -- "<client> <name> :<why>", or "<client> :<why>"
            fail('%s: %s', command, msg[#msg] or 'refused')
            return true
        elseif noted[n] then
            if noted[n](msg[2]) then table.insert(l.errors, msg) end
        elseif n == 'ACK' then
            finish()
            return true
        elseif kept(msg) then
            table.insert(l.messages, msg)
        end
    end

    local timeout_ms = spec.timeout_ms or 120000
    local replies
    if spec.unlabeled then
        t:send(first, table.unpack(spec.args, 2))
        replies = function() return t:wait_irc(commands, timeout_ms) end
    else
        replies = t:request(commands, timeout_ms, first, table.unpack(spec.args, 2))
    end
    for msg in replies do
        if step(msg) then return end
    end
    if queued then leave(t.net, spec.key, t.id) end
    fail('%s: %s', command, spec.silence or 'no reply')
end

-- Another server answers later than ours, so its replies are told by
-- their source, when what was asked of is a server's name (a nick or a
-- mask names none): the names an end must have, and the rows to keep.
local function by_source(t, server)
    local irc = HUB.state.nets[t.net] and HUB.state.nets[t.net].irc
    if irc and server and server:find '%.' and not server:find '[*?]' then
        local key = irc_model.fold(irc, server)
        return {field = 'source', name = key},
            function(msg) return msg.source ~= nil and irc_model.fold(irc, msg.source) == key end
    end
end

--- STATS a letter, of a server or ours.
---@param t hub.Task
---@param letter string one character
---@param server string|nil
function M.stats(t, letter, server)
    local names, from = by_source(t, server)
    gather(t, {
        kind = 'stats',
        args = {'STATS', letter, server},
        target = server,
        rows = stats_rows,
        ends = stats_ends,
        -- "<client> <letter> :End of /STATS report"
        key = 'stats ' .. letter,
        names = names,
        from = from,
    })
end

--- The MOTD of a server, a nick's, or ours.
---@param t hub.Task
---@param target string|nil
function M.motd(t, target)
    local names, from = by_source(t, target)
    gather(t, {kind = 'motd', args = {'MOTD', target}, target = target, rows = motd_rows,
        ends = motd_ends, key = 'motd', names = names, from = from})
end

--- The INFO of a server, a nick's, or ours.
---@param t hub.Task
---@param target string|nil
function M.info(t, target)
    local names, from = by_source(t, target)
    gather(t, {kind = 'info', args = {'INFO', target}, target = target, rows = info_rows,
        ends = info_ends, key = 'info', names = names, from = from})
end

local function trace_gather(t, spec)
    local irc = HUB.state.nets[t.net] and HUB.state.nets[t.net].irc
    spec.key = 'trace'
    spec.ends = trace_ends
    -- for a target, an end naming it; else any
    if irc and spec.target then
        spec.names = {field = 2, name = irc_model.fold(irc, spec.target)}
    end
    gather(t, spec)
end

--- TRACE a server or a nick, or our server.
---@param t hub.Task
---@param target string|nil
function M.trace(t, target)
    trace_gather(t, {kind = 'trace', args = {'TRACE', target}, target = target, rows = trace_rows})
end

-- ETRACE's options, as each server has them; anything else is a nick
local etrace_options <const> = {['-full'] = true, ['-v4'] = true, ['-v6'] = true}
local etrace_options_hybrid <const> = {['-full'] = true}

--- ETRACE: an option (-full; on Solanum -v4, -v6), a nick, or our
--- server's users.
---@param t hub.Task
---@param arg string|nil
function M.etrace(t, arg)
    local options = ircd.hybrid(t.net) and etrace_options_hybrid or etrace_options
    local target = arg and not options[arg:lower()] and arg or nil
    trace_gather(t, {kind = 'etrace', args = {'ETRACE', arg}, target = target, rows = etrace_rows})
end

--- MASKTRACE the users that match [nick!]user@host, and a realname mask.
---@param t hub.Task
---@param mask string
---@param gecos string|nil
function M.masktrace(t, mask, gecos)
    trace_gather(t, {kind = 'masktrace', args = {'MASKTRACE', mask, gecos}, rows = etrace_rows,
        relabel = {class = 'server'}})
end

--- CHANTRACE the users of a channel: one we're on, or any with ! before
--- its name (operspy). The end names our server, not the channel, so
--- any end is taken. The errors name the channel as looked up: without
--- the ! when we have operspy, with it when we don't.
---@param t hub.Task
---@param channel string
function M.chantrace(t, channel)
    gather(t, {kind = 'chantrace', args = {'CHANTRACE', channel}, target = channel,
        rows = etrace_rows, ends = trace_ends, key = 'trace', relabel = {class = 'server'}})
end

--- HELP on a topic, or the index. The server answers it itself, in the
--- order asked, so any end is taken.
---@param t hub.Task
---@param topic string|nil
function M.help(t, topic)
    gather(t, {kind = 'help', args = {'HELP', topic}, rows = help_rows, ends = help_ends, key = 'help',
        lines = {under = N.RPL_HELPTXT}})
end

--- MODLIST the modules whose names match a pattern (all without one), of
--- a server or ours; a server needs a pattern before it.
---@param t hub.Task
---@param pattern string|nil
---@param server string|nil
function M.modlist(t, pattern, server)
    local names, from = by_source(t, server)
    gather(t, {kind = 'modlist', args = {'MODLIST', pattern, server}, target = server, rows = modlist_rows,
        ends = modlist_ends, key = 'modlist', names = names, from = from})
end

--- LUSERS of a server or ours: the counts of users, operators,
--- channels and servers, as lines.
---@param t hub.Task
---@param server string|nil
function M.lusers(t, server)
    local names, from = by_source(t, server)
    local ends = lusers_ends
    if ircd.hybrid(t.net) then
        local irc = HUB.state.nets[t.net] and HUB.state.nets[t.net].irc
        if not (irc and irc.mode.o) then ends = lusers_ends_hidden end
    end
    -- the mask before a server is obsolete, but must be there
    gather(t, {kind = 'lusers', args = server and {'LUSERS', '*', server} or {'LUSERS'}, target = server,
        rows = lusers_rows, ends = ends, key = 'lusers', names = names, from = from, unlabeled = true,
        lines = {under = N.RPL_LUSERCLIENT, middle = true}})
end

--- PRIVS of a nick, or ours: the privileges of its oper block, its
--- operator and privset names, and its auth block's exemptions, a row
--- each. The nick's server answers, naming it in every line.
---@param t hub.Task
---@param nick string|nil
function M.privs(t, nick)
    local irc = HUB.state.nets[t.net] and HUB.state.nets[t.net].irc
    local names, from
    local target = nick or (irc and irc.nick)
    if irc and target then
        local key = irc_model.fold(irc, target)
        names = {field = 2, name = key}
        from = function(msg) return msg[2] ~= nil and irc_model.fold(irc, msg[2]) == key end
    end
    gather(t, {kind = 'privs', args = {'PRIVS', nick}, target = nick, rows = privs_rows, ends = privs_ends,
        key = 'privs', names = names, from = from, unended = true, timeout_ms = 30000,
        silence = 'no reply, as the server gives when there are no privileges',
        lines = {under = N.RPL_PRIVS, column = 'privilege', strip = '^%* ', words = true}})
end

--- SCAN UMODES: the users with some user modes and without others, and
--- how many, by the options as Solanum reads them (modules/m_scan.c).
---@param t hub.Task
---@param args string[] the modes, then the options, as sent after UMODES
function M.scan(t, args)
    gather(t, {kind = 'scan', args = {'SCAN', 'UMODES', table.unpack(args)}, rows = scan_rows, ends = scan_ends,
        key = 'scan'})
end

--- Whether a mask is one MASKTRACE takes: a user and a host about the
--- first @, the user after a nick and ! if there is one. The server
--- answers another with only a notice.
---@param mask string
---@return boolean
function M.masktrace_mask(mask)
    local left, host = mask:match '^([^@]*)@(.*)$'
    if not left then return false end
    local user = left:match '!(.*)$' or left
    return user ~= '' and host ~= ''
end

return M
