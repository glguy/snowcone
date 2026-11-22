-- Replies that list things, gathered as a network task into a
-- hub.Listing, logged as one line that opens it, and emitted as
-- listing.ready for the UI to show as tables (ui/details/listing.lua):
--
--   M.stats(t, letter, server)   STATS, ending at RPL_ENDOFSTATS for its letter
--   M.trace(t, target)           TRACE, ending at RPL_ENDOFTRACE
--   M.etrace(t, arg)             ETRACE, ending at RPL_ENDOFTRACE
--   M.masktrace(t, mask, gecos)  MASKTRACE, ending at RPL_ENDOFTRACE
--
-- Every reply but the end is kept, in order, except the errors: those
-- that end a reply fail the task (no such server or nick, naming the
-- target; the command unknown or short of arguments, naming it; no
-- privileges for an oper command; OFTC hybrid's refusal of a STATS for
-- load, which no end follows), and those the server follows with the end
-- (a STATS refused for privileges, load, or as disabled; STATS's short of
-- arguments on hybrid) are kept apart, to show above the tables.
--
-- Without labeled-response the replies of every listing pending arrive
-- mixed, but in the order the commands went out. The listings that end
-- alike (the STATS of a letter; the traces, all with RPL_ENDOFTRACE) wait
-- in a queue per network in the order sent, and an end goes to the first
-- that takes it: any, or for a trace of a target, one naming the target.
-- The rows before an end that isn't a listing's own belong to another,
-- and are dropped.

local bus       <const> = require 'hub.runtime.bus'
local irc_model <const> = require 'hub.net.irc'
local ircd      <const> = require 'hub.net.ircd'
local log       <const> = require 'hub.runtime.log'
local N         <const> = require 'hub.lib.numerics'

--- A listing: what was asked, and the replies.
---@class hub.Listing
---@field kind 'stats'|'trace'|'etrace'|'masktrace'
---@field command string as sent, with its arguments
---@field messages hub.Message[] the replies, in order
---@field errors hub.Message[] errors the server followed with the end
---@field relabel table<string, string>|nil field labels that mean
--- something else in this reply: MASKTRACE gives each user's server
--- where ETRACE gives the class
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

-- The queue an end belongs to, nil for a message that isn't one
local function end_key(msg)
    if msg.command == N.RPL_ENDOFSTATS then return 'stats ' .. tostring(msg[2]) end
    if msg.command == N.RPL_ENDOFTRACE then return 'trace' end
end

-- Unlabeled listings waiting for their end, by network and key, in the
-- order sent: {id, accepts(msg)}; and which task each end went to
local queues = {}
local claims <const> = setmetatable({}, {__mode = 'k'})

local function queue(net, key)
    local by_key = queues[net]
    if not by_key then
        by_key = {}
        queues[net] = by_key
    end
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
local function owner(net, msg)
    local id = claims[msg]
    if id ~= nil then return id end
    local q = queue(net, end_key(msg))
    for i = #q, 1, -1 do
        if not HUB.tasks[q[i].id] then table.remove(q, i) end
    end
    id = false
    for i, entry in ipairs(q) do
        if entry.accepts(msg) then
            id = entry.id
            table.remove(q, i)
            break
        end
    end
    claims[msg] = id
    return id
end

---@param t hub.Task
---@param spec {kind: string, args: string[], target: string|nil, rows: table<integer, true>,
--- key: string, accepts: fun(msg: hub.Message): boolean, from: (fun(msg: hub.Message): boolean)|nil,
--- relabel: table<string, string>|nil}
local function gather(t, spec)
    local command = table.concat(spec.args, ' ')
    ---@type hub.Listing
    local l = {kind = spec.kind, command = command, messages = {}, errors = {}, relabel = spec.relabel,
        at = os.time()}

    local function fail(fmt, ...)
        t:log(spec.kind, fmt, ...)
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
    elseif spec.kind ~= 'trace' then
        -- the oper commands; TRACE is anyone's
        fatal[N.ERR_NOPRIVILEGES] = any
    end

    local commands = {[N.RPL_ENDOFSTATS] = true, [N.RPL_ENDOFTRACE] = true}
    for set in pairs {[spec.rows] = true, [fatal] = true, [noted] = true} do
        for k in pairs(set) do commands[k] = true end
    end

    -- with labels every end in the reply is ours
    local queued = irc ~= nil and not irc_model.has_labels(irc)
    if queued then table.insert(queue(t.net, spec.key), {id = t.id, accepts = spec.accepts}) end
    local function mine(msg)
        if not queued then return end_key(msg) == spec.key end
        return owner(t.net, msg) == t.id
    end

    for msg in t:request(commands, 120000, first, table.unpack(spec.args, 2)) do
        local n = msg.command
        if end_key(msg) then
            if mine(msg) then
                local count = #l.messages
                l.at = os.time()
                log.add_detail(t.net, spec.kind, {kind = 'listing', data = l}, '%s: %d %s%s', command, count,
                    count == 1 and 'reply' or 'replies', #l.errors > 0 and ', refused' or '')
                bus.emit('listing.ready', {net = t.net, listing = l})
                return
            elseif queued then
                -- another listing's: what came before it was its own
                l.messages, l.errors = {}, {}
            end
        elseif fatal[n] and fatal[n](msg[2]) then
            if queued then leave(t.net, spec.key, t.id) end
            -- "<client> <name> :<why>", or "<client> :<why>"
            return fail('%s: %s', command, msg[#msg] or 'refused')
        elseif noted[n] then
            if noted[n](msg[2]) then table.insert(l.errors, msg) end
        elseif spec.rows[n] and (not spec.from or spec.from(msg)) then
            table.insert(l.messages, msg)
        end
    end
    if queued then leave(t.net, spec.key, t.id) end
    fail('%s: no reply', command)
end

--- STATS a letter, of a server or ours.
---@param t hub.Task
---@param letter string one character
---@param server string|nil
function M.stats(t, letter, server)
    -- another server answers later than ours, so its replies are told by
    -- their source, when what was asked for is a server's name (a nick or
    -- a mask names none)
    local from
    local irc = HUB.state.nets[t.net] and HUB.state.nets[t.net].irc
    if irc and server and server:find '%.' and not server:find '[*?]' then
        local key = irc_model.fold(irc, server)
        from = function(msg) return msg.source ~= nil and irc_model.fold(irc, msg.source) == key end
    end
    gather(t, {
        kind = 'stats',
        args = {'STATS', letter, server},
        target = server,
        rows = stats_rows,
        -- "<client> <letter> :End of /STATS report"
        key = 'stats ' .. letter,
        accepts = from or function() return true end,
        from = from,
    })
end

-- An end a trace takes: any, or for a target, one naming it
local function trace_accepts(irc, target)
    if not target then return function() return true end end
    return function(msg)
        return msg[2] ~= nil and irc_model.fold(irc, msg[2]) == irc_model.fold(irc, target)
    end
end

local function trace_gather(t, spec)
    local irc = HUB.state.nets[t.net] and HUB.state.nets[t.net].irc
    spec.key = 'trace'
    spec.accepts = irc and trace_accepts(irc, spec.target)
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
