-- Channel operator commands: /mode, quiets and bans, kick and kickban,
-- and op and voice. They act on the shown channel; whether we may is the
-- server's to say.

local ban_mask  <const> = require 'hub.features.chat.masks'
local bus       <const> = require 'hub.runtime.bus'
local chat      <const> = require 'hub.features.chat'
local common    <const> = require 'hub.features.common'
local irc_model <const> = require 'hub.net.irc'
local lookup    <const> = require 'hub.features.queries.lookup'
local send      <const> = require 'hub.net.send'
local task      <const> = require 'hub.runtime.task'

local M = {}

local command <const> = common.net_command(chat.name)

local function model(net)
    local rec = HUB.state.nets[net]
    return rec and rec.irc
end

--- The shown channel, for a command that acts on it. Whether we may is
--- the server's to say: halfops and opers with override can, unopped.
function M.shown_channel(ctx)
    local irc = model(ctx.net)
    local target = ctx.target
    if not (target and irc and irc_model.is_channel_name(irc, target)) then
        error('not a channel: ' .. tostring(target or 'no buffer'), 0)
    end
    return target
end

-- A mask given as one, or a nick to look up
local function is_mask(text)
    return text:find '[!@$]' ~= nil
end

-- Set or unset (change is +b, -q, ...) a list mode on the ban mask of a
-- nick, looking it up first, and kick it when kick is a reason
---@param t hub.Task
local function ban_nick(t, channel, nick, change, kick)
    local found, err = lookup(t, nick)
    if not found then return t:log('chat', '%s', err) end
    t:send('MODE', channel, change, '*!' .. ban_mask(found.user, found.ip, found.host))
    if kick == '' then
        t:send('KICK', channel, found.nick)
    elseif kick then
        t:send('KICK', channel, found.nick, kick)
    end
    chat.refetch_observed(t.net, channel)
end

-- Set a list mode: a mask as given (an extban too), or a nick's ban mask
local function ban_command(name, mode, help)
    return command(name, '$g', 'mask|nick', help, function(ctx, arg)
        local channel = M.shown_channel(ctx)
        if is_mask(arg) then
            send.send(ctx.net, 'MODE', channel, '+' .. mode, arg)
            chat.refetch_observed(ctx.net, channel)
        else
            task.spawn(name, {net = ctx.net, owner = chat.name}, ban_nick, channel, arg, '+' .. mode)
        end
    end)
end

-- Unset a list mode: a mask as given, or a nick's ban mask
local function unban_command(name, mode, help)
    local cmd = command(name, '$g', 'mask|nick', help, function(ctx, arg)
        local channel = M.shown_channel(ctx)
        if is_mask(arg) then
            send.send(ctx.net, 'MODE', channel, '-' .. mode, arg)
            chat.refetch_observed(ctx.net, channel)
        else
            task.spawn(name, {net = ctx.net, owner = chat.name}, ban_nick, channel, arg, '-' .. mode)
        end
    end)
    -- Tab offers the list's masks and the channel's nicks; a list not yet
    -- fetched is asked for, for the next Tab
    function cmd.complete(ctx, before, seed)
        if before ~= '' then return nil end
        local irc = model(ctx.net)
        local channel = irc and ctx.target and irc_model.known_channel(irc, ctx.target)
        if not channel then return nil end
        local entries = channel.list_modes[mode]
        if not entries then
            chat.fetch_list(ctx.net, channel.name, mode)
            return nil
        end
        local t = {}
        local starts = chat.name_matcher(ctx.net, seed)
        local function offer(s)
            if starts(s) then table.insert(t, s) end
        end
        for mask in pairs(entries) do offer(mask) end
        for _, member in pairs(channel.members) do offer(member.user.nick) end
        return t[1] and t or nil
    end
    return cmd
end

-- Send changes ({sign, flag, argument or nil}) to a channel's modes, in
-- order, in as few MODE lines as the server's MODES allows arguments
local function send_changes(net, irc, channel, changes)
    -- MODES with no value sets no limit
    local limit = irc.isupport.MODES
    local per = limit == true and math.huge or math.tointeger(tonumber(limit)) or 3
    per = math.max(per, 1)
    local line = {changes = {}, args = {}}
    local lines = {line}
    for _, change in ipairs(changes) do
        if change[3] then
            if #line.args == per then
                line = {changes = {}, args = {}}
                table.insert(lines, line)
            end
            table.insert(line.args, change[3])
        end
        table.insert(line.changes, change)
    end
    for _, l in ipairs(lines) do
        local modestring, sign = {}, nil
        for _, change in ipairs(l.changes) do
            if change[1] ~= sign then
                sign = change[1]
                table.insert(modestring, sign)
            end
            table.insert(modestring, change[2])
        end
        send.send(net, 'MODE', channel, table.concat(modestring), table.unpack(l.args))
    end
end

-- Give (+o) or take (-o) a prefix mode for nicks in the shown channel, in
-- as few MODE lines as the server's MODES allows; with no nicks, bare()
local function prefix_command(name, change, help, bare)
    return command(name, '$R', '[nick...]', help, function(ctx, args)
        local channel = M.shown_channel(ctx)
        local changes = {}
        local sign, mode = change:sub(1, 1), change:sub(2)
        for nick in args:gmatch '[^ ]+' do table.insert(changes, {sign, mode, nick}) end
        if not changes[1] then return bare(ctx.net, channel) end
        local irc = model(ctx.net)
        ---@cast irc -nil shown_channel needs it
        send_changes(ctx.net, irc, channel, changes)
    end)
end

-- The changes a modestring makes, {sign, flag, takes an argument}, by the
-- network's modes; a letter it doesn't have is an error. A change with
-- no sign before it sets.
local function parse_modestring(irc, modestring)
    local changes, sign = {}, '+'
    for flag in modestring:gmatch '.' do
        if flag == '+' or flag == '-' then
            sign = flag
        else
            local takes = irc_model.mode_takes_arg(irc, sign, flag)
            if takes == nil then error('not a channel mode here: ' .. flag, 0) end
            table.insert(changes, {sign, flag, takes})
        end
    end
    return changes
end

-- What a mode's argument is, for its placeholder; another mode's shows
-- as the change, such as +j
local argument_names <const> = {k = 'key', l = 'limit'}

-- /mode's line as the network's modes read it: the modestring, red in the
-- letters the network doesn't have and red whole without any letter,
-- then a word for each change that takes an argument, and any words past
-- those as one, red. Still to come, the modestring, then the arguments of
-- the changes not yet given, by what they are: nick for a prefix mode,
-- mask for a list. When every change sets a list, as +b does, and none is
-- given yet, they are optional: alone they show it.
local function mode_shape(ctx, rest, slot)
    local words = {}
    for lo, word in rest:gmatch '()([^ ]+)' do
        table.insert(words, {lo = lo, hi = lo + #word - 1, word = word})
    end
    if not words[1] then return {words = {}, ghosts = {slot[1]}} end

    local irc = model(ctx.net)
    local shown = {}
    if not irc then
        for i, w in ipairs(words) do shown[i] = {lo = w.lo, hi = w.hi, ok = true} end
        return {words = shown, ghosts = {}}
    end

    -- the modestring, in runs of letters known and not
    local first = words[1]
    local changes, sign, lists, letters = {}, '+', true, 0
    for i = 1, #first.word do
        local flag = first.word:sub(i, i)
        local ok = true
        if flag == '+' or flag == '-' then
            sign = flag
        else
            letters = letters + 1
            local takes = irc_model.mode_takes_arg(irc, sign, flag)
            if takes == nil then
                ok = false
            elseif takes then
                table.insert(changes, {sign, flag})
            end
            if not (sign == '+' and irc.modes_A:find(flag, 1, true)) then lists = false end
        end
        local last = shown[#shown]
        if last and last.ok == ok then
            last.hi = first.lo + i - 1
        else
            table.insert(shown, {lo = first.lo + i - 1, hi = first.lo + i - 1, ok = ok, final = true})
        end
    end
    if letters == 0 then
        shown = {{lo = first.lo, hi = first.hi, ok = false}}
    end

    -- the arguments, and those left over as one
    for i = 2, math.min(#words, #changes + 1) do
        table.insert(shown, {lo = words[i].lo, hi = words[i].hi, ok = true})
    end
    if #words > #changes + 1 then
        table.insert(shown, {lo = words[#changes + 2].lo, hi = words[#words].hi, ok = false, final = true})
    end

    local ghosts = {}
    for i = #words, #changes do
        local s, flag = changes[i][1], changes[i][2]
        local label = irc.mode_to_prefix[flag] and 'nick'
            or irc.modes_A:find(flag, 1, true) and 'mask'
            or argument_names[flag] or s .. flag
        table.insert(ghosts, {label = label, optional = lists and #words == 1, repeats = false})
    end
    return {words = shown, ghosts = ghosts}
end

-- /mode: changes checked against the network's modes, or the modes shown
local function mode_command()
    local cmd = command('mode', '$R', '[modes [arg...]]',
        "Change the shown channel's modes, e.g. +nt-s or +k key; with none, or only list modes like +b, show them",
    function(ctx, args)
        local channel = M.shown_channel(ctx)
        local irc = model(ctx.net)
        ---@cast irc -nil shown_channel needs it
        local words = {}
        for word in args:gmatch '[^ ]+' do table.insert(words, word) end
        local modestring = table.remove(words, 1)
        if not modestring then
            chat.refresh_modes(ctx.net, channel)
            bus.emit('chat.show_channel', {net = ctx.net, target = channel})
            return
        end

        local parsed = parse_modestring(irc, modestring)
        if not parsed[1] then error('no modes: ' .. modestring, 0) end

        -- only lists asked for, such as +b or +bq: fetch them, to show
        if not words[1] then
            local lists = true
            for _, change in ipairs(parsed) do
                if not (change[1] == '+' and irc.modes_A:find(change[2], 1, true)) then
                    lists = false
                end
            end
            if lists then
                for _, change in ipairs(parsed) do chat.fetch_list(ctx.net, channel, change[2]) end
                bus.emit('chat.show_channel', {net = ctx.net, target = channel})
                return
            end
        end

        local changes, n = {}, 0
        for _, change in ipairs(parsed) do
            local sign, flag, takes = change[1], change[2], change[3]
            local arg
            if takes then
                n = n + 1
                arg = words[n]
                if not arg then error(sign .. flag .. ' needs an argument', 0) end
            end
            table.insert(changes, {sign, flag, arg})
        end
        if words[n + 1] then
            error('more arguments than the modes take: ' .. words[n + 1], 0)
        end
        send_changes(ctx.net, irc, channel, changes)
        chat.refetch_observed(ctx.net, channel)
    end)

    cmd.shape = mode_shape

    -- Tab on a change's argument offers what fits it: the channel's nicks
    -- for a prefix mode, a list's masks to unset (fetching a list not yet
    -- fetched, for the next Tab), the key to unset
    function cmd.complete(ctx, before, seed)
        local irc = model(ctx.net)
        local channel = irc and ctx.target and irc_model.known_channel(irc, ctx.target)
        if not channel then return nil end
        ---@cast irc -nil the channel came from it
        local words = {}
        for word in before:gmatch '[^ ]+' do table.insert(words, word) end
        if not words[1] then return nil end
        local ok, parsed = pcall(parse_modestring, irc, words[1])
        if not ok then return nil end

        -- the change whose argument is being typed
        local change, n = nil, 0
        for _, c in ipairs(parsed) do
            if c[3] then
                n = n + 1
                if n == #words then change = c break end
            end
        end
        if not change then return nil end
        local sign, flag = change[1], change[2]

        local t = {}
        local starts = chat.name_matcher(ctx.net, seed)
        local function offer(s)
            if starts(s) then table.insert(t, s) end
        end
        if irc.mode_to_prefix[flag] then
            for _, member in pairs(channel.members) do offer(member.user.nick) end
        elseif sign == '-' and irc.modes_A:find(flag, 1, true) then
            local entries = channel.list_modes[flag]
            if not entries then
                chat.fetch_list(ctx.net, channel.name, flag)
                return nil
            end
            for mask in pairs(entries) do offer(mask) end
        elseif sign == '-' and channel.modes and type(channel.modes[flag]) == 'string' then
            offer(channel.modes[flag])
        end
        table.sort(t)
        return t[1] and t or nil
    end
    return cmd
end

-- Ask ChanServ (Atheme) for a prefix mode of our own
local function from_chanserv(request)
    return function(net, channel)
        send.send(net, 'PRIVMSG', 'ChanServ', request .. ' ' .. channel)
    end
end

-- Drop a prefix mode of our own, which needs no services
local function drop_own(change)
    return function(net, channel)
        send.send(net, 'MODE', channel, change, model(net).nick)
    end
end

M.commands = {
    mode_command(),
    ban_command('quiet', 'q', 'Quiet a mask, or a nick by its ban mask, in the shown channel'),
    ban_command('ban', 'b', 'Ban a mask, or a nick by its ban mask, from the shown channel'),
    command('kick', '$a $T', 'nick [reason]', 'Kick a nick from the shown channel', function(ctx, nick, reason)
        local channel = M.shown_channel(ctx)
        if reason ~= '' then
            send.send(ctx.net, 'KICK', channel, nick, reason)
        else
            send.send(ctx.net, 'KICK', channel, nick)
        end
    end),
    command('kickban', '$a $T', 'nick [reason]', 'Ban a nick from the shown channel and kick it',
    function(ctx, nick, reason)
        local channel = M.shown_channel(ctx)
        task.spawn('kickban', {net = ctx.net, owner = chat.name}, ban_nick, channel, nick, '+b', reason)
    end),
    unban_command('unquiet', 'q', 'Unquiet a mask, or a nick by its ban mask, in the shown channel'),
    unban_command('unban', 'b', 'Unban a mask, or a nick by its ban mask, from the shown channel'),
    prefix_command('op', '+o', 'Op nicks in the shown channel, or ourselves through ChanServ',
        from_chanserv 'OP'),
    prefix_command('deop', '-o', 'Deop nicks in the shown channel, or ourselves', drop_own '-o'),
    prefix_command('voice', '+v', 'Voice nicks in the shown channel, or ourselves through ChanServ',
        from_chanserv 'VOICE'),
    prefix_command('devoice', '-v', 'Devoice nicks in the shown channel, or ourselves', drop_own '-v'),
}

return M
