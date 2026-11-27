-- Replies that list things, gathered as a network task into a
-- hub.Listing, logged as one line that opens it, and emitted as
-- query.listing for the UI to show as tables (ui/details/listing.lua):
--
--   M.stats(t, letter, server)    STATS
--   M.trace(t, target)            TRACE
--   M.etrace(t, arg)              ETRACE
--   M.masktrace(t, mask, gecos)   MASKTRACE
--   M.chantrace(t, channel)       CHANTRACE
--   M.motd(t, target)             MOTD
--   M.info(t, target)             INFO
--   M.help(t, topic)              HELP
--   M.modlist(t, pattern, server) MODLIST
--   M.lusers(t, server)           LUSERS
--   M.privs(t, nick)              PRIVS
--   M.scan(t, args)               SCAN UMODES
--   M.list(t, filter)             LIST
--
-- Each kind says what it lists and what ends it (hub.ListingSpec); gather
-- does the rest. The replies it lists are kept in order until the end,
-- which may be one of them too, or may say there is nothing to list and
-- fail the task. Errors about the listing either fail it, when no end
-- follows them, or are kept apart, to show above the tables, when one
-- does. Every listing fails on no such server or nick naming its target,
-- and on its command unknown or short of arguments; it notes a refusal
-- for load or for an oper privilege; an oper command fails on not being
-- an oper. A kind adds to or changes these.
--
-- Without labeled-response the replies of every listing pending arrive
-- mixed, but in the order the commands went out. The listings that end
-- alike wait in a queue per network in the order sent, and an end goes to
-- the first that takes it: any, or one about the listing's target
-- (hub.ListingAbout). The rows before an end that isn't a listing's own
-- belong to another, and are dropped, unless they are told apart by what
-- they name. A listing may go without a label on a network that has them,
-- for a reply the server labels wrongly.

local bus       <const> = require 'hub.runtime.bus'
local common    <const> = require 'hub.features.common'
local irc_model <const> = require 'hub.net.irc'
local ircd      <const> = require 'hub.net.ircd'
local log       <const> = require 'hub.runtime.log'
local N         <const> = require 'hub.lib.numerics'
local NH        <const> = require 'hub.lib.numerics_hybrid'

--- A listing: what was asked, and the replies.
---@class hub.Listing
---@field kind string the command's, as the log names it
---@field command string as sent, with its arguments, unless the kind
--- shows it otherwise
---@field messages hub.Message[] the replies, in order
---@field errors hub.Message[] errors the server followed with the end
---@field relabel table<string, string>|nil field labels that mean
--- something else in this reply: MASKTRACE and CHANTRACE give each
--- user's server where ETRACE gives the class
---@field lines hub.ListingLines|nil when the replies are lines of text
---@field at integer epoch seconds when the end came
---@field sort hub.ListingSort|nil how its tables are sorted at first
---@field view table|nil the UI's tables, worked out once (ui/details/listing.lua)

--- Replies shown as lines of text, in one table: each reply's last
--- argument, less `strip`; with `words`, a row for each of its words.
---@class hub.ListingLines
---@field under integer the numeric to show them all under
---@field column string|nil the column's header; default text
---@field strip string|nil a Lua pattern to take off the start
---@field words boolean|nil

--- A column, by its header, that a listing's tables are sorted by until
--- another is chosen.
---@class hub.ListingSort
---@field header string
---@field descending boolean

--- What a listing is about, for telling its replies from another's
--- without labels: the field of an end that must name `name`, and with
--- `rows`, of each row too.
---@class hub.ListingAbout
---@field field 'source'|2
---@field name string folded
---@field rows boolean|nil

--- How an error goes: 'fatal' fails the listing, 'noted' keeps it for the
--- tables; and when it is about this listing, by its second argument:
--- naming the target, naming the command, any, or as a function says.
---@alias hub.ListingError {[1]: 'fatal'|'noted', [2]: 'target'|'command'|'any'|fun(name: string|nil): boolean}

--- An end: true, 'row' for one that is a reply to keep as well, 'fails'
--- for one that says there is nothing to list; or a function of the
--- reply giving one of those, or nil for a reply that isn't an end.
---@alias hub.ListingEnd true|'row'|'fails'|fun(msg: hub.Message): true|'row'|'fails'|nil

--- What a kind of listing lists and how it ends.
---@class hub.ListingSpec
---@field kind string
---@field args string[] the command and its arguments
---@field target string|nil what errors about it name
---@field rows table<integer, true> the replies it lists
---@field ends table<integer, hub.ListingEnd>
---@field key string its queue: the listings whose ends are alike
---@field key_of (fun(msg: hub.Message): string)|nil an end's queue, when
--- it depends on the end (a STATS letter)
---@field about hub.ListingAbout|nil
---@field oper boolean|nil an oper command, failing when we aren't one
---@field errors table<integer, hub.ListingError|false>|nil to add to or
--- change the defaults; false drops one
---@field unended boolean|nil a labeled reply may have no end: an ACK
--- shows an empty listing
---@field unlabeled boolean|nil sent without a label
---@field timeout_ms integer|nil
---@field silence string|nil what the log says on no reply
---@field relabel table<string, string>|nil
---@field lines hub.ListingLines|nil
---@field shown string|nil the command as the log and the tables show
--- it, when not as sent
---@field sort hub.ListingSort|nil

local M = {}

local function range(set, lo, hi)
    for n = lo, hi do set[n] = true end
    return set
end

-- The errors of every listing
local default_errors <const> = {
    [N.ERR_NOSUCHSERVER] = {'fatal', 'target'},
    [N.ERR_NOSUCHNICK] = {'fatal', 'target'},
    [N.ERR_UNKNOWNCOMMAND] = {'fatal', 'command'},
    [N.ERR_NEEDMOREPARAMS] = {'fatal', 'command'},
    [N.RPL_LOAD2HI] = {'noted', 'command'},
    [N.ERR_NOPRIVS] = {'noted', 'any'},
}

-- An oper privilege refused with no end after it
local privs_without_end <const> = {[N.ERR_NOPRIVS] = {'fatal', 'any'}}

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

-- The task an end of a queue goes to: the first in the queue still
-- running that takes it, worked out by the first task to see it; false
-- for none
local function owner(net, irc, key, msg)
    local S = get(net)
    if S.claim and S.claim.msg == msg then return S.claim.id end
    local q = queue(net, key)
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

---@param irc table|nil
---@param name string|nil
---@return string|nil
local function folded(irc, name)
    return irc and name and irc_model.fold(irc, name)
end

local function model(net)
    return HUB.state.nets[net] and HUB.state.nets[net].irc
end

---@param t hub.Task
---@param spec hub.ListingSpec
local function gather(t, spec)
    local command = spec.shown or table.concat(spec.args, ' ')
    ---@type hub.Listing
    local l = {kind = spec.kind, command = command, messages = {}, errors = {}, relabel = spec.relabel,
        lines = spec.lines, sort = spec.sort, at = os.time()}

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
    -- a network without a connection fails with a message from the send
    local irc = model(t.net)
    local target = folded(irc, spec.target)
    local tests <const> = {
        target = function(name) return target ~= nil and folded(irc, name) == target end,
        command = function(name) return name ~= nil and name:upper() == first end,
        any = function() return true end,
    }

    -- the errors, by how they go: each a test of the name in the error
    local fatal, noted = {}, {}
    local errors = {}
    for n, e in pairs(default_errors) do errors[n] = e end
    if spec.oper then errors[N.ERR_NOPRIVILEGES] = {'fatal', 'any'} end
    for n, e in pairs(spec.errors or {}) do errors[n] = e or nil end
    for n, e in pairs(errors) do
        local how, test = e[1], e[2]
        local set = how == 'fatal' and fatal or noted
        set[n] = type(test) == 'function' and test or tests[test]
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
    local about = spec.about
    if queued then
        table.insert(queue(t.net, spec.key), {id = t.id, field = about and about.field, name = about and about.name})
    end
    local function mine(msg)
        if not queued then return true end
        return owner(t.net, irc, spec.key_of and spec.key_of(msg) or spec.key, msg) == t.id
    end

    local function kept(msg)
        if not spec.rows[msg.command] then return false end
        if not (about and about.rows) then return true end
        return folded(irc, msg[about.field]) == about.name
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
            elseif queued and not (about and about.rows) then
                -- another listing's: what came before it was its own
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
-- mask names none).
---@return hub.ListingAbout|nil
local function by_source(t, server)
    local irc = model(t.net)
    if irc and server and server:find '%.' and not server:find '[*?]' then
        return {field = 'source', name = irc_model.fold(irc, server), rows = true}
    end
end

-- STATS lists its letter's replies to "<client> <letter> :End of /STATS
-- report", and gives refusals for privileges, load or as disabled before
-- the end, as hybrid does arguments short; hybrid's refusal for load has
-- no end after it
local stats_rows <const> = range({}, 210, 250)
local stats_ends <const> = {[N.RPL_ENDOFSTATS] = true}

--- STATS a letter, of a server or ours.
---@param t hub.Task
---@param letter string one character
---@param server string|nil
function M.stats(t, letter, server)
    local errors = {
        [N.ERR_NOPRIVILEGES] = {'noted', 'any'},
        -- "<client> STATS <letter> :This command has been administratively disabled"
        [N.ERR_DISABLED] = {'noted', function(name) return name ~= nil and name:upper():find '^STATS' ~= nil end},
        [N.ERR_NEEDMOREPARAMS] = {'noted', 'command'},
    }
    if ircd.hybrid(t.net) then errors[N.RPL_LOAD2HI] = {'fatal', 'command'} end
    gather(t, {kind = 'stats', args = {'STATS', letter, server}, target = server, rows = stats_rows,
        ends = stats_ends, key = 'stats ' .. letter,
        key_of = function(msg) return 'stats ' .. tostring(msg[2]) end,
        about = by_source(t, server), errors = errors})
end

-- MOTD and INFO list their lines (the start of each only names the
-- server); no MOTD comes in place of the end
local motd_rows <const> = {[N.RPL_MOTD] = true}
local motd_ends <const> = {[N.RPL_ENDOFMOTD] = true, [N.ERR_NOMOTD] = 'fails'}
local info_rows <const> = {[N.RPL_INFO] = true}
local info_ends <const> = {[N.RPL_ENDOFINFO] = true}

--- The MOTD of a server, a nick's, or ours.
---@param t hub.Task
---@param target string|nil
function M.motd(t, target)
    gather(t, {kind = 'motd', args = {'MOTD', target}, target = target, rows = motd_rows,
        ends = motd_ends, key = 'motd', about = by_source(t, target)})
end

--- The INFO of a server, a nick's, or ours.
---@param t hub.Task
---@param target string|nil
function M.info(t, target)
    gather(t, {kind = 'info', args = {'INFO', target}, target = target, rows = info_rows,
        ends = info_ends, key = 'info', about = by_source(t, target)})
end

-- The traces all end at RPL_ENDOFTRACE, naming the target asked of; all
-- but TRACE are oper commands
local trace_rows <const> = range({[N.RPL_TRACELOG] = true}, 200, 209)
local etrace_rows <const> = {[N.RPL_ETRACE] = true, [N.RPL_ETRACEFULL] = true}
local trace_ends <const> = {[N.RPL_ENDOFTRACE] = true}

local function trace_gather(t, spec)
    local irc = model(t.net)
    spec.key = 'trace'
    spec.ends = trace_ends
    -- for a target, an end naming it; else any
    if irc and spec.target then
        spec.about = {field = 2, name = irc_model.fold(irc, spec.target)}
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
    trace_gather(t, {kind = 'etrace', args = {'ETRACE', arg}, target = target, rows = etrace_rows, oper = true})
end

--- MASKTRACE the users that match [nick!]user@host, and a realname mask.
---@param t hub.Task
---@param mask string
---@param gecos string|nil
function M.masktrace(t, mask, gecos)
    trace_gather(t, {kind = 'masktrace', args = {'MASKTRACE', mask, gecos}, rows = etrace_rows, oper = true,
        relabel = {class = 'server'}})
end

--- CHANTRACE the users of a channel: one we're on, or any with ! before
--- its name (operspy). The end names our server, not the channel, so
--- any end is taken. No such channel, and not on it, fail it, naming the
--- channel as looked up: without the ! when we have operspy, with it
--- when we don't.
---@param t hub.Task
---@param channel string
function M.chantrace(t, channel)
    local irc = model(t.net)
    local key = folded(irc, channel)
    local function is_channel(name)
        return key ~= nil and name ~= nil and (folded(irc, name) == key or folded(irc, '!' .. name) == key)
    end
    gather(t, {kind = 'chantrace', args = {'CHANTRACE', channel}, target = channel, rows = etrace_rows,
        ends = trace_ends, key = 'trace', oper = true, relabel = {class = 'server'},
        errors = {[N.ERR_NOSUCHCHANNEL] = {'fatal', is_channel}, [N.ERR_NOTONCHANNEL] = {'fatal', is_channel}}})
end

-- HELP lists its first line and the rest as lines of text; no such topic
-- comes in place of the end
local help_rows <const> = {[N.RPL_HELPSTART] = true, [N.RPL_HELPTXT] = true}
local help_ends <const> = {[N.RPL_ENDOFHELP] = true, [N.ERR_HELPNOTFOUND] = 'fails'}

--- HELP on a topic, or the index. The server answers it itself, in the
--- order asked, so any end is taken.
---@param t hub.Task
---@param topic string|nil
function M.help(t, topic)
    gather(t, {kind = 'help', args = {'HELP', topic}, rows = help_rows, ends = help_ends, key = 'help',
        lines = {under = N.RPL_HELPTXT}})
end

local modlist_rows <const> = {[N.RPL_MODLIST] = true}
local modlist_ends <const> = {[N.RPL_ENDOFMODLIST] = true}

--- MODLIST the modules whose names match a pattern (all without one), of
--- a server or ours; a server needs a pattern before it. Refused for the
--- admin privilege with no end after.
---@param t hub.Task
---@param pattern string|nil
---@param server string|nil
function M.modlist(t, pattern, server)
    gather(t, {kind = 'modlist', args = {'MODLIST', pattern, server}, target = server, rows = modlist_rows,
        ends = modlist_ends, key = 'modlist', about = by_source(t, server), oper = true, errors = privs_without_end})
end

-- LUSERS ends at RPL_STATSCONN, but on hybrid, which sends it only to
-- opers or when servers aren't hidden, at RPL_GLOBALUSERS for others
local lusers_rows <const> = range({[N.RPL_LOCALUSERS] = true, [N.RPL_GLOBALUSERS] = true}, 250, 255)
local lusers_ends <const> = {[N.RPL_STATSCONN] = 'row'}
local lusers_ends_hidden <const> = {[N.RPL_GLOBALUSERS] = 'row'}

--- LUSERS of a server or ours: the counts of users, operators, channels
--- and servers. It goes without a label: Solanum's handler for an oper
--- batches nothing, so only its first line would be labeled.
---@param t hub.Task
---@param server string|nil
function M.lusers(t, server)
    local ends = lusers_ends
    if ircd.hybrid(t.net) then
        local irc = model(t.net)
        if not (irc and irc.mode.o) then ends = lusers_ends_hidden end
    end
    -- the mask before a server is obsolete, but must be there
    gather(t, {kind = 'lusers', args = server and {'LUSERS', '*', server} or {'LUSERS'}, target = server,
        rows = lusers_rows, ends = ends, key = 'lusers', about = by_source(t, server), unlabeled = true})
end

-- PRIVS's lines each name the nick; its last is the one without the "* "
-- that says more follow
local privs_rows <const> = {[N.RPL_PRIVS] = true}
local privs_ends <const> = {
    [N.RPL_PRIVS] = function(msg) return not (msg[#msg] or ''):find '^%* ' and 'row' or nil end,
}

--- PRIVS of a nick, or ours: the privileges of its oper block, its
--- operator and privset names, and its auth block's exemptions, a row
--- each. The nick's server answers. Someone with nothing to show has no
--- reply at all: with labels an ACK; without, the wait runs out. Another's
--- needs an oper, with the privs privilege, refused with no end after.
---@param t hub.Task
---@param nick string|nil
function M.privs(t, nick)
    local irc = model(t.net)
    local about
    local name = folded(irc, nick or (irc and irc.nick))
    if name then about = {field = 2, name = name, rows = true} end
    gather(t, {kind = 'privs', args = {'PRIVS', nick}, target = nick, rows = privs_rows, ends = privs_ends,
        key = 'privs', about = about, oper = true, errors = privs_without_end, unended = true,
        timeout_ms = 30000, silence = 'no reply, as the server gives when there are no privileges',
        lines = {under = N.RPL_PRIVS, column = 'privilege', strip = '^%* ', words = true}})
end

local scan_rows <const> = {[N.RPL_SCANUMODES] = true, [N.RPL_SCANMATCHED] = true}
local scan_ends <const> = {[N.RPL_SCANMATCHED] = 'row'}

--- SCAN UMODES: the users with some user modes and without others, and
--- how many, by the options as Solanum reads them (modules/m_scan.c).
--- A global listing needs operspy, refused with no end after.
---@param t hub.Task
---@param args string[] the modes, then the options, as sent after UMODES
function M.scan(t, args)
    gather(t, {kind = 'scan', args = {'SCAN', 'UMODES', table.unpack(args)}, rows = scan_rows, ends = scan_ends,
        key = 'scan', oper = true, errors = privs_without_end})
end

-- LIST's channels, until its end. Both servers refuse a LIST paced for
-- load, Solanum with the end after; OFTC hybrid refuses bad filters with
-- ERR_LISTSYNTAX and no end. Solanum answers a channel named alone and
-- not there with no such nick. A second LIST while one runs stops it and
-- lists nothing (/list sends none, features/queries/init.lua). The
-- server's order means nothing, so the biggest channels come first.
local list_rows <const> = {[N.RPL_LIST] = true}
local list_ends <const> = {[N.RPL_LISTEND] = true}

--- LIST the channels a filter picks (features/queries/list.lua).
---@param t hub.Task
---@param filter hub.ListFilter
function M.list(t, filter)
    local errors = {[N.RPL_LOAD2HI] = {'fatal', 'command'}}
    if ircd.hybrid(t.net) then errors[NH.ERR_LISTSYNTAX] = {'fatal', 'any'} end
    -- a big network's list is long in coming
    gather(t, {kind = 'list', args = {'LIST', filter.arg}, shown = filter.shown, target = filter.channel,
        rows = list_rows, ends = list_ends, key = 'list', errors = errors, timeout_ms = 300000,
        sort = {header = 'users', descending = true}})
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
