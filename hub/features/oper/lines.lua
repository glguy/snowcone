-- Oper commands for the network's bans as typed, with the arguments as
-- Solanum's handlers read them (modules/m_kline.c, m_dline.c, m_xline.c,
-- m_resv.c), and its wallops (m_wallops.c):
--
--   /unkline user@host [ON server]
--   /dline [duration] address[/prefix] [ON server] [reason]
--   /undline address[/prefix] [ON server]
--   /xline [duration] realname [ON server] reason
--   /unxline realname [ON server]
--   /resv [duration] channel|nick [ON server] reason
--   /unresv channel|nick [ON server]
--   /wallops text
--   /operwall text
--
-- The line is read as the server reads the parameters: a first word that
-- is a duration is the duration, then the target, then ON and a server
-- when ON (in any case) has a word after it, and the rest the reason,
-- sent as the last parameter. A word that can't be what it stands for is
-- refused before anything goes out, as the server would refuse it with
-- only a notice. OFTC hybrid's syntax is the same, but its durations are
-- minutes as a number.
--
-- These go out as typed. Staging with a count first, and the reasons and
-- tags of the servers file, are for /kline and the views (oper/init.lua).

local common    <const> = require 'hub.features.common'
local irc_param <const> = require 'hub.lib.irc_param'
local ircd      <const> = require 'hub.net.ircd'
local send      <const> = require 'hub.net.send'

local M = {}

-- Durations ===========================================================

--- Whether a word is a duration as Solanum's valid_temp_time reads it:
--- numbers, each with a unit of m, h, d or w but the last, which may go
--- without (minutes): 30, 1d, 1d12h, 2w3.
---@param word string
---@return boolean
function M.solanum_duration(word)
    local pos = 1
    while pos <= #word do
        -- strtol: a sign, then digits
        local digits, after = word:match('^([+-]?%d+)()', pos)
        if not digits or tonumber(digits) < 0 then return false end
        local unit = word:sub(after, after)
        if unit == '' then return true end
        if not unit:find '^[mhdw]$' then return false end
        pos = after + 1
    end
    return true
end

-- Whether a word is a duration on the network: on OFTC hybrid, minutes
local function is_duration(net, word)
    if ircd.hybrid(net) then return word:find '^%d+$' ~= nil end
    return M.solanum_duration(word)
end

-- Targets =============================================================

--- What Solanum's parse_netmask makes of a mask: 'ip' for an address with
--- an optional /prefix, 'error' for a prefix too long or followed by
--- more when `strict` (as DLINE has it), and 'host' for anything else.
---@param text string
---@param strict boolean
---@return 'ip'|'error'|'host'
function M.netmask(text, strict)
    if text:find '[*?]' then return 'host' end
    local max
    if text:find(':', 1, true) then
        max = 128
    elseif text:find('.', 1, true) then
        max = 32
    else
        return 'host'
    end
    local address, prefix = text:match '^([^/]*)/(.*)$'
    if prefix then
        local digits, after = prefix:match '^([+-]?%d+)(.*)$'
        if not digits or tonumber(digits) < 0 then return 'host' end
        if strict and (tonumber(digits) > max or after ~= '') then return 'error' end
    else
        address = text
    end
    return snowcone.pton(address) and 'ip' or 'host'
end

-- Why a target can't be one, or nil when it can

-- "<user>@<host>", "*...", or a host with a . or :
local function unkline_target(mask)
    if mask:find '@' or mask:find '^%*' or mask:find '[.:]' then return nil end
    return 'not a user@host or host: ' .. mask
end

-- A host alone is *@host to UNKLINE; sent so, an address like ::1 can go
-- before ON
local function unkline_as_sent(mask)
    if mask:find '^:' and not mask:find '@' then return '*@' .. mask end
    return mask
end

local function dline_target(mask)
    if mask:find '^:' then return 'an address can\'t start with ":": ' .. mask end
    local kind = M.netmask(mask, true)
    if kind == 'error' then return 'a prefix past the address: ' .. mask end
    if kind ~= 'ip' then return 'not an address[/prefix]: ' .. mask end
end

local function undline_target(mask)
    if M.netmask(mask, false) ~= 'ip' then return 'not an address[/prefix]: ' .. mask end
end

-- Lines ===============================================================

--- How a command's line reads.
---@class hub.LineGrammar
---@field command string sent
---@field duration boolean|nil a first word may be a duration
---@field target (fun(word: string): string|nil)|nil why a target can't be one
---@field as_sent (fun(word: string): string)|nil the target as it goes out,
--- when it can't go as typed
---@field reason 'required'|'optional'|nil whether a reason follows

--- A line read by its grammar. words are as typed, each with the part it
--- is: duration, target, on, server, reason (the rest of the line, one
--- word from its first byte to the end), or leftover (the words past what
--- a command without a reason takes, as one).
---@class hub.LineParse
---@field words {lo: integer, hi: integer, part: string, ok: boolean}[]
---@field duration string|nil
---@field target string|nil
---@field server string|nil
---@field reason string|nil
---@field on_alone boolean|nil an ON with nothing after it yet
---@field err string|nil why it can't be sent

---@param net string
---@param g hub.LineGrammar
---@param rest string
---@return hub.LineParse
local function parse(net, g, rest)
    local words = {}
    for lo, word in rest:gmatch '()([^ ]+)' do
        table.insert(words, {lo = lo, hi = lo + #word - 1, word = word})
    end
    ---@type hub.LineParse
    local p = {words = {}}
    local function fail(err) p.err = p.err or err end
    local function take(w, part, err)
        local entry = {lo = w.lo, hi = w.hi, part = part, ok = err == nil}
        table.insert(p.words, entry)
        if err then fail(err) end
        return entry
    end

    local i = 1
    if g.duration and words[i] and is_duration(net, words[i].word) then
        p.duration = words[i].word
        take(words[i], 'duration')
        i = i + 1
    end

    local target = words[i]
    if not target then
        fail(p.duration and 'no target after the duration ' .. p.duration or 'no target')
        return p
    end
    p.target = g.as_sent and g.as_sent(target.word) or target.word
    local target_entry = take(target, 'target', g.target and g.target(target.word))
    local server_entry
    i = i + 1

    local on = words[i]
    if on and on.word:upper() == 'ON' then
        if words[i + 1] then
            p.server = words[i + 1].word
            take(on, 'on')
            server_entry = take(words[i + 1], 'server')
            i = i + 2
        elseif not g.reason then
            -- the server would take it for nothing
            p.on_alone = true
            take(on, 'on', 'no server after ON')
            i = i + 1
        else
            -- the server takes it for the reason; the line shows it as ON
            -- while a server may follow
            p.on_alone = true
        end
    end

    local first = words[i]
    if first then
        if g.reason then
            p.reason = rest:sub(first.lo, words[#words].hi)
            table.insert(p.words, {lo = first.lo, hi = words[#words].hi, part = 'reason', ok = true})
        else
            table.insert(p.words, {lo = first.lo, hi = words[#words].hi, part = 'leftover', ok = false})
            fail('more than ' .. g.command .. ' takes: ' .. rest:sub(first.lo, words[#words].hi))
        end
    elseif g.reason == 'required' then
        fail(g.command .. ' needs a reason')
    end

    -- only the last parameter can start with ":"; the reason, when there
    -- is one, is last
    local function middle(entry, value, last)
        if entry and not last and not irc_param.middle(value) then
            entry.ok = false
            fail(irc_param.not_middle(value))
        end
    end
    middle(target_entry, p.target, not p.server and not p.reason)
    middle(server_entry, p.server or '', not p.reason)
    return p
end

-- The parts of every grammar, in the order of their usage's placeholders
local parts <const> = {'duration', 'target', 'on', 'server', 'reason'}

-- The line as the input line shows it: each part apart, red when it can't
-- be what it stands for, the reason as message text. Still to come, the
-- placeholders after the last part typed.
local function shaper(g)
    -- the usage's placeholders, by part
    local has = {duration = g.duration, target = true, on = true, server = true, reason = g.reason ~= nil}
    return function(ctx, rest, slot)
        local p = parse(ctx.net, g, rest)
        local words, last = {}, 0
        for _, w in ipairs(p.words) do
            local part = w.part
            if p.on_alone and part == 'reason' then part = 'on' end
            table.insert(words, {lo = w.lo, hi = w.hi, ok = w.ok or p.on_alone and part == 'on',
                final = part == 'leftover', text = part == 'reason'})
            for k, name in ipairs(parts) do
                if name == part then last = math.max(last, k) end
            end
            -- nothing more fits past words left over
            if part == 'leftover' then last = #parts end
        end
        local ghosts, n = {}, 0
        for k, part in ipairs(parts) do
            if has[part] then
                n = n + 1
                local ghost = slot[n]
                if k > last and ghost then
                    -- after ON, its server is needed
                    if part == 'server' and last == 3 then
                        ghost = {label = ghost.label, optional = false, repeats = false}
                    end
                    table.insert(ghosts, ghost)
                end
            end
        end
        return {words = words, ghosts = ghosts}
    end
end

-- Tab after ON offers servers; elsewhere, the default
local function completer(g)
    return function(ctx, before, seed)
        if parse(ctx.net, g, before).on_alone then return common.complete_server(ctx.net, seed) end
    end
end

local oper_command <const> = common.net_command('oper')

---@param name string
---@param usage string
---@param help string
---@param g hub.LineGrammar
local function line_command(name, usage, help, g)
    local cmd = oper_command(name, '$r', usage, help, function(ctx, rest)
        local p = parse(ctx.net, g, rest)
        if p.err then error(p.err, 0) end
        local args = {}
        if p.duration then table.insert(args, p.duration) end
        table.insert(args, p.target)
        if p.server then
            table.insert(args, 'ON')
            table.insert(args, p.server)
        end
        if p.reason then table.insert(args, p.reason) end
        send.send(ctx.net, g.command, table.unpack(args))
    end, completer(g))
    cmd.shape = shaper(g)
    return cmd
end

local function wall_command(name, help)
    return oper_command(name, '$t', 'text', help, function(ctx, text)
        send.send(ctx.net, name:upper(), text)
    end)
end

M.commands = {
    line_command('unkline', 'user@host [ON server]', 'UNKLINE a mask, on a server or the network',
        {command = 'UNKLINE', target = unkline_target, as_sent = unkline_as_sent}),
    line_command('dline', '[duration] address[/prefix] [ON server] [reason]',
        'D-Line an address or range, on a server or the network, for a duration or for good',
        {command = 'DLINE', duration = true, target = dline_target, reason = 'optional'}),
    line_command('undline', 'address[/prefix] [ON server]', 'UNDLINE an address or range',
        {command = 'UNDLINE', target = undline_target}),
    line_command('xline', '[duration] realname [ON server] reason',
        'X-Line a realname mask, on a server or the network, for a duration or for good',
        {command = 'XLINE', duration = true, reason = 'required'}),
    line_command('unxline', 'realname [ON server]', 'UNXLINE a realname mask',
        {command = 'UNXLINE'}),
    line_command('resv', '[duration] channel|nick [ON server] reason',
        'RESV a channel or nick mask, on a server or the network, for a duration or for good',
        {command = 'RESV', duration = true, reason = 'required'}),
    line_command('unresv', 'channel|nick [ON server]', 'UNRESV a channel or nick mask',
        {command = 'UNRESV'}),
    wall_command('wallops', 'Send a WALLOPS to everyone with +w'),
    wall_command('operwall', 'Send an OPERWALL to the opers with +z'),
}

return M
