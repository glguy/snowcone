-- Queries: what a user asks of the server and reads as a reply, on any
-- network, whatever features it has. Each runs as a network task, logs
-- one line that opens the reply, and emits it for the UI to show:
--
--   who.lua       WHO
--   whois.lua     WHOIS
--   whowas.lua    WHOWAS
--   listing.lua   STATS, TRACE, ETRACE, MASKTRACE, CHANTRACE, MOTD, INFO,
--                 HELP, LUSERS, PRIVS, SCAN, LIST (its filters in
--                 list.lua), and MODLIST for the admin feature
--   accept.lua    ACCEPT's list, after each change to it too
--
-- and FINDFORWARDS, which the server answers with a notice that shows as
-- any other.
--
-- and, for features to ask on the way to something else:
--
--   lookup.lua    a user's username, host and address, for a ban
--   testmask.lua  reading TESTMASK's count
--   ip_org.lua    the organization of an address (a local database)
--
-- This module holds their commands. Not a feature of a network but always
-- loaded; any feature may require these modules, and they require no
-- feature's.

local accept    <const> = require 'hub.features.queries.accept'
local common    <const> = require 'hub.features.common'
local irc_model <const> = require 'hub.net.irc'
local ircd      <const> = require 'hub.net.ircd'
local list      <const> = require 'hub.features.queries.list'
local listing   <const> = require 'hub.features.queries.listing'
local log       <const> = require 'hub.runtime.log'
local send      <const> = require 'hub.net.send'
local task      <const> = require 'hub.runtime.task'
local who       <const> = require 'hub.features.queries.who'
local whois     <const> = require 'hub.features.queries.whois'
local whowas    <const> = require 'hub.features.queries.whowas'

local M = {}

M.name = 'queries'

local function model(net)
    local rec = HUB.state.nets[net]
    return rec and rec.irc
end

-- A command on a network, whatever its features
---@param name string
---@param spec string
---@param usage string|nil
---@param help string
---@param fn function
---@param complete hub.Complete|nil
---@return table
local function command(name, spec, usage, help, fn, complete)
    return {name = name, spec = spec, usage = usage, scope = 'net', group = M.name, help = help, fn = fn,
        complete = complete}
end

--- Change the accept list, each word a nick to add or -nick to take off,
--- then show it as it is, in the detail pane. Not connected, it logs so.
---@param net string
---@param words string[] none only shows it
function M.accept(net, words)
    local rec = HUB.state.nets[net]
    if not (rec and rec.phase == 'connected') then
        return log.add_net(net, accept.name, '%s is not connected', net)
    end
    if words[1] then send.send(net, 'ACCEPT', table.concat(words, ',')) end
    accept.fetch(net)
end

--- WHOIS a nick, on its server (with idle time) if `remote`; the reply
--- opens in the detail pane.
---@param net string
---@param nick string
---@param remote boolean|nil
function M.whois(net, nick, remote)
    task.spawn('whois', {net = net, owner = M.name}, whois, nick, remote or false)
end

-- Tab on the options offers formats for what a WHO is mostly for:
-- every field (bar the token and oplevel), who's who and addresses;
-- and o, alone or with every field, for operators only. The address is asked for only while
-- we're opered, as the server hides it from the rest, and the
-- channel not for a channel's WHO, as it would be the same on every
-- row. A server without WHOX takes o only after the mask 0.
local function complete_who(ctx, before, seed)
    local words = {}
    for word in before:gmatch '[^ ]+' do table.insert(words, word) end
    if #words == 0 then return nil end -- the mask: nicks and channels
    if #words > 1 then return {} end
    local irc = model(ctx.net)
    if not irc then return {} end
    local mask = words[1]
    local offered
    if not irc.isupport.WHOX then
        offered = mask == '0' and {'o'} or {}
    else
        local channel = irc_model.is_channel_name(irc, mask:match '^!(.+)$' or mask)
        local function format(letters)
            if channel then letters = letters:gsub('c', '') end
            if not irc.mode.o then letters = letters:gsub('i', '') end
            return '%' .. letters
        end
        local all = format 'cuihsnfdlar'
        offered = {all, format 'cnfar', format 'nuihar', 'o', 'o' .. all}
    end
    local t = {}
    for _, option in ipairs(offered) do
        if option:sub(1, #seed) == seed then table.insert(t, option) end
    end
    return t
end

local function who_command()
    return command('who', '$a $R', 'mask [options]',
        'WHO a channel, nick or mask; options are o for operators only, then a WHOX %format',
    function(ctx, mask, options)
        if options:find ' ' then error('options are one word: ' .. options, 0) end
        -- a server without WHOX would answer a format with the plain
        -- reply, not the one asked for, and reads a +flags or -flags
        -- mask as a search whose end the task can't tell
        local irc = model(ctx.net)
        if irc and not irc.isupport.WHOX then
            if select(2, who.parse_options(options)) then
                error(ctx.net .. ' does not support WHOX formats', 0)
            elseif mask:find '^[+-]' then
                error(ctx.net .. ' reads ' .. mask .. ' as a search by flags; send it with /quote WHO', 0)
            end
        end
        task.spawn('who', {net = ctx.net, owner = M.name}, who.run, mask, options ~= '' and options or nil)
    end, complete_who)
end

-- SCAN's options, as Solanum reads them, each true when it takes a value
local scan_options <const> = {['no-list'] = false, list = false, global = false, ['list-max'] = true, mask = true}

local function complete_scan(_, before, seed)
    if not before:find '%S' then return {} end
    local options = {}
    for option in pairs(scan_options) do table.insert(options, option) end
    return common.starting(options, seed)
end

local function scan_command()
    return command('scan', '$a $R', '+modes[-modes] [option...]',
        'SCAN UMODES: the users with modes and without others, shown as a table; options are no-list, '
            .. 'global (operspy, with a list), list-max n and mask nick!user@host',
    function(ctx, modes, rest)
        if ircd.hybrid(ctx.net) then error('OFTC hybrid has no SCAN', 0) end
        if not modes:find '^[+-]' then error('modes start with + or -: ' .. modes, 0) end
        local args = {modes}
        local words = {}
        for w in rest:gmatch '%S+' do table.insert(words, w) end
        local i = 1
        while i <= #words do
            local option = words[i]:lower()
            local takes = scan_options[option]
            if takes == nil then error('not a SCAN option: ' .. words[i], 0) end
            table.insert(args, option)
            if takes then
                local value = words[i + 1]
                if not value then error(option .. ' takes a value', 0) end
                if option == 'list-max' and not math.tointeger(tonumber(value)) then
                    error('list-max takes a number: ' .. value, 0)
                end
                table.insert(args, value)
                i = i + 1
            end
            i = i + 1
        end
        task.spawn('scan', {net = ctx.net, owner = M.name}, listing.scan, args)
    end, complete_scan)
end

-- A LIST running on a network: another would stop it, and list nothing
local function listing_channels(net)
    for _, t in pairs(HUB.tasks) do
        if t.name == 'list' and t.net == net then return true end
    end
    return false
end

local function list_command()
    return command('list', '$R', '[filter...]',
        'LIST the channels, shown as a table; filters: #mask or *mask*, !mask to leave out, '
            .. '>n or <n users, C<n or C>n created within or over n minutes ago, '
            .. 'T<n or T>n topic set within or over n minutes ago, as the network offers them '
            .. '(ELIST); without one a server may leave out small channels, which >0 lists',
    function(ctx, rest)
        local irc = model(ctx.net)
        if not irc then error(ctx.net .. ' is not connected', 0) end
        if listing_channels(ctx.net) then error('a LIST is running on ' .. ctx.net, 0) end
        local words = {}
        for w in rest:gmatch '[^%s,]+' do table.insert(words, w) end
        local filter = list.parse(ctx.net, irc, words)
        task.spawn('list', {net = ctx.net, owner = M.name}, listing.list, filter)
    end)
end

function M.subscribe(sub)
    sub.on('net.removed', function(ev)
        common.drop_state(M.name, ev.net)
        accept.drop(ev.net)
    end)
end

-- Tab on a command's lone argument, a server or nick: the servers
-- starting with it, or else the default
local function server_or_nick(ctx, before, seed)
    if before:find '%S' then return {} end
    local t = common.complete_server(ctx.net, seed)
    return t[1] and t or nil
end

-- ETRACE's options, as Solanum reads them
local etrace_options <const> = {'-full', '-v4', '-v6'}

M.commands = {
    who_command(),
    command('stats', '$a $R', 'letter [server]', "STATS a letter, of a server or ours, shown as tables",
    function(ctx, letter, server)
        -- the server takes the first byte, and names it in the end
        if not letter:match '^%g$' then error('a STATS letter is one ASCII character: ' .. letter, 0) end
        if server:find ' ' then error('one server: ' .. server, 0) end
        task.spawn('stats', {net = ctx.net, owner = M.name}, listing.stats, letter,
            server ~= '' and server or nil)
    end, common.server_at(1)),
    command('trace', '$R', '[target]', 'TRACE a server or nick, or ours, shown as tables',
    function(ctx, target)
        if target:find ' ' then error('one target: ' .. target, 0) end
        task.spawn('trace', {net = ctx.net, owner = M.name}, listing.trace, target ~= '' and target or nil)
    end, server_or_nick),
    command('motd', '$R', '[target]', "The MOTD of a server or nick's, or ours, shown as a table",
    function(ctx, target)
        if target:find ' ' then error('one target: ' .. target, 0) end
        task.spawn('motd', {net = ctx.net, owner = M.name}, listing.motd, target ~= '' and target or nil)
    end, server_or_nick),
    command('info', '$R', '[target]', "The INFO of a server or nick's, or ours, shown as a table",
    function(ctx, target)
        if target:find ' ' then error('one target: ' .. target, 0) end
        task.spawn('info', {net = ctx.net, owner = M.name}, listing.info, target ~= '' and target or nil)
    end, server_or_nick),
    command('lusers', '$R', '[server]', 'LUSERS: the counts of users, operators, channels and servers',
    function(ctx, server)
        if server:find ' ' then error('one server: ' .. server, 0) end
        task.spawn('lusers', {net = ctx.net, owner = M.name}, listing.lusers, server ~= '' and server or nil)
    end, common.server_at(0)),
    command('privs', '$R', '[nick]', "PRIVS: a nick's operator privileges, or ours, shown as a table",
    function(ctx, nick)
        if ircd.hybrid(ctx.net) then error('OFTC hybrid has no PRIVS', 0) end
        if nick:find ' ' then error('one nick: ' .. nick, 0) end
        task.spawn('privs', {net = ctx.net, owner = M.name}, listing.privs, nick ~= '' and nick or nil)
    end, common.default_first()),
    scan_command(),
    list_command(),
    command('findforwards', '$g', 'channel', 'FINDFORWARDS: the channels that forward (+f) to a channel',
    function(ctx, channel)
        if ircd.hybrid(ctx.net) then error('OFTC hybrid has no FINDFORWARDS', 0) end
        local irc = model(ctx.net)
        if irc and not irc_model.is_channel_name(irc, channel) then error('not a channel: ' .. channel, 0) end
        send.send(ctx.net, 'FINDFORWARDS', channel)
    end, common.default_first()),
    -- /help is ours
    -- the server's topics are its own
    command('serverhelp', '$R', '[topic]', "The server's HELP on a topic, or its index, shown as a table",
    function(ctx, topic)
        if topic:find ' ' then error('one topic: ' .. topic, 0) end
        task.spawn('help', {net = ctx.net, owner = M.name}, listing.help, topic ~= '' and topic or nil)
    end, common.complete_nothing),
    command('whois', '$g', 'nick', 'WHOIS a nick, shown in the detail pane', function(ctx, nick)
        M.whois(ctx.net, nick)
    end, common.default_first()),
    command('wii', '$a', 'nick', 'WHOIS a nick on its server (with idle time)', function(ctx, nick)
        M.whois(ctx.net, nick, true)
    end, common.default_first()),
    command('whowas', '$a $R', 'nick [count]', 'WHOWAS a nick, at most count entries',
    function(ctx, nick, count)
        local n
        if count ~= '' then
            n = math.tointeger(tonumber(count))
            if not n or n < 1 then error('count must be a positive number: ' .. count, 0) end
        end
        task.spawn('whowas', {net = ctx.net, owner = M.name}, whowas, nick, n)
    end, common.default_first()),
    command('masktrace', '$a $R', '[nick!]user@host [realname]',
        'MASKTRACE the users a mask matches, shown as a table',
    function(ctx, mask, gecos)
        if ircd.hybrid(ctx.net) then error('OFTC hybrid has no MASKTRACE', 0) end
        if not listing.masktrace_mask(mask) then error('not a [nick!]user@host mask: ' .. mask, 0) end
        task.spawn('masktrace', {net = ctx.net, owner = M.name}, listing.masktrace, mask,
            gecos ~= '' and gecos or nil)
    end, common.default_first()),
    command('chantrace', '$g', '[!]channel',
        "CHANTRACE a channel's users, shown as a table; ! for one we aren't on (operspy)",
    function(ctx, channel)
        if ircd.hybrid(ctx.net) then error('OFTC hybrid has no CHANTRACE', 0) end
        local irc = model(ctx.net)
        if irc and not irc_model.is_channel_name(irc, channel:match '^!(.+)$' or channel) then
            error('not a channel: ' .. channel, 0)
        end
        task.spawn('chantrace', {net = ctx.net, owner = M.name}, listing.chantrace, channel)
    end, common.default_first()),
    command('etrace', '$R', '[-full|-v4|-v6|nick]', "ETRACE our server's users, or a nick, shown as a table",
    function(ctx, arg)
        if arg:find ' ' then error('one argument: ' .. arg, 0) end
        task.spawn('etrace', {net = ctx.net, owner = M.name}, listing.etrace, arg ~= '' and arg or nil)
    end, function(_, before, seed)
        -- an option, or else a nick
        if before:find '%S' then return {} end
        if seed:sub(1, 1) ~= '-' then return nil end
        return common.starting(etrace_options, seed)
    end),
    command('accept', '$R', '[[-]nick...]',
        'Let nicks message us past +g (caller ID), or with - no longer, then show the list; with none, show it',
    function(ctx, rest)
        local words = {}
        for word in rest:gmatch '%S+' do
            -- the server reads a , as between nicks and a * first as the list
            if not word:match '^%-?[^,*-][^,*]*$' then error('not a nick or -nick: ' .. word, 0) end
            table.insert(words, word)
        end
        M.accept(ctx.net, words)
    end),
}

return M
