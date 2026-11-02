-- Channel operator commands: /mode, quiets and bans, kickban, and op and
-- voice. They act on the shown channel; whether we may is the server's
-- to say. Chat requires this module, so it passes itself in.

local ban_mask  <const> = require 'hub.features.chat.masks'
local bus       <const> = require 'hub.runtime.bus'
local irc_model <const> = require 'hub.net.irc'
local lookup    <const> = require 'hub.features.lookup'
local send      <const> = require 'hub.net.send'
local task      <const> = require 'hub.runtime.task'

local M = {}

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
end

-- Set a list mode on a nick's ban mask
local function ban_command(chat, name, mode, help)
    return chat.command(name, '$g', 'nick', help, function(ctx, nick)
        local channel = M.shown_channel(ctx)
        task.spawn(name, {net = ctx.net, owner = chat.name}, ban_nick, channel, nick, '+' .. mode)
    end)
end

-- Unset a list mode: a mask as given, or a nick's ban mask
local function unban_command(chat, name, mode, help)
    local cmd = chat.command(name, '$g', 'mask|nick', help, function(ctx, arg)
        local channel = M.shown_channel(ctx)
        if is_mask(arg) then
            send.send(ctx.net, 'MODE', channel, '-' .. mode, arg)
        else
            task.spawn(name, {net = ctx.net, owner = chat.name}, ban_nick, channel, arg, '-' .. mode)
        end
    end)
    -- Tab offers the list's masks and the channel's nicks; a list not yet
    -- fetched is asked for, for the next Tab
    function cmd.complete(ctx, before, seed)
        if before ~= '' then return nil end
        local irc = model(ctx.net)
        local channel = irc and ctx.target and irc_model.get_channel(irc, ctx.target)
        if not channel then return nil end
        local entries = channel.list_modes[mode]
        if not entries then
            chat.fetch_list(ctx.net, channel.name, mode)
            return nil
        end
        local t = {}
        local function offer(s)
            if s:sub(1, #seed) == seed then table.insert(t, s) end
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
local function prefix_command(chat, name, change, help, bare)
    return chat.command(name, '$R', '[nick...]', help, function(ctx, args)
        local channel = M.shown_channel(ctx)
        local changes = {}
        local sign, mode = change:sub(1, 1), change:sub(2)
        for nick in args:gmatch '%g+' do table.insert(changes, {sign, mode, nick}) end
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

-- /mode: changes checked against the network's modes, or the modes shown
local function mode_command(chat)
    local cmd = chat.command('mode', '$R', '[modes [arg...]]',
        "Change the shown channel's modes, e.g. +nt-s or +k key; with none, or only list modes like +b, show them",
    function(ctx, args)
        local channel = M.shown_channel(ctx)
        local irc = model(ctx.net)
        ---@cast irc -nil shown_channel needs it
        local words = {}
        for word in args:gmatch '%g+' do table.insert(words, word) end
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
    end)

    -- Tab on a change's argument offers what fits it: the channel's nicks
    -- for a prefix mode, a list's masks to unset (fetching a list not yet
    -- fetched, for the next Tab), the key to unset
    function cmd.complete(ctx, before, seed)
        local irc = model(ctx.net)
        local channel = irc and ctx.target and irc_model.get_channel(irc, ctx.target)
        if not channel then return nil end
        ---@cast irc -nil the channel came from it
        local words = {}
        for word in before:gmatch '%g+' do table.insert(words, word) end
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
        local function offer(s)
            if s:sub(1, #seed) == seed then table.insert(t, s) end
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
local function from_chanserv(command)
    return function(net, channel)
        send.send(net, 'PRIVMSG', 'ChanServ', command .. ' ' .. channel)
    end
end

-- Drop a prefix mode of our own, which needs no services
local function drop_own(change)
    return function(net, channel)
        send.send(net, 'MODE', channel, change, model(net).nick)
    end
end

--- The commands, made for chat.
---@param chat hub.Chat
function M.commands(chat)
    return {
        mode_command(chat),
        ban_command(chat, 'quiet', 'q', 'Quiet a nick in the shown channel'),
        ban_command(chat, 'ban', 'b', 'Ban a nick from the shown channel'),
        chat.command('kickban', '$g $R', 'nick [reason]', 'Ban a nick from the shown channel and kick it',
        function(ctx, nick, reason)
            local channel = M.shown_channel(ctx)
            task.spawn('kickban', {net = ctx.net, owner = chat.name}, ban_nick, channel, nick, '+b', reason)
        end),
        unban_command(chat, 'unquiet', 'q', 'Unquiet a mask, or a nick by its ban mask, in the shown channel'),
        unban_command(chat, 'unban', 'b', 'Unban a mask, or a nick by its ban mask, from the shown channel'),
        prefix_command(chat, 'op', '+o', 'Op nicks in the shown channel, or ourselves through ChanServ',
            from_chanserv 'OP'),
        prefix_command(chat, 'deop', '-o', 'Deop nicks in the shown channel, or ourselves', drop_own '-o'),
        prefix_command(chat, 'voice', '+v', 'Voice nicks in the shown channel, or ourselves through ChanServ',
            from_chanserv 'VOICE'),
        prefix_command(chat, 'devoice', '-v', 'Devoice nicks in the shown channel, or ourselves', drop_own '-v'),
    }
end

return M
