-- Chat's commands: talking (/cmsg a private message shown in a channel),
-- buffers, channel information, WHO, WHOIS and WHOWAS, STATS and TRACE, and our user modes; the
-- channel operator commands are in chat/modes.lua. Chat requires this module, so it passes itself in.

local bus       <const> = require 'hub.runtime.bus'
local irc_model <const> = require 'hub.net.irc'
local listing   <const> = require 'hub.features.listing'
local modes     <const> = require 'hub.features.chat.modes'
local send      <const> = require 'hub.net.send'
local task      <const> = require 'hub.runtime.task'
local who       <const> = require 'hub.features.chat.who'
local whowas    <const> = require 'hub.features.chat.whowas'

local M = {}

local function model(net)
    local rec = HUB.state.nets[net]
    return rec and rec.irc
end

local function close_command(chat)
    local cmd = chat.command('close', '$R', '[target]',
        'Close a buffer, the shown one by default, parting its channel',
    function(ctx, target)
        if target == '' then
            target = ctx.target
        end
        if not target then
            error('no buffer to close', 0)
        end
        chat.close(ctx.net, target)
    end)

    -- Tab offers the network's open buffers
    function cmd.complete(ctx, before, seed)
        if before ~= '' then return nil end
        local t = {}
        local starts = chat.name_matcher(ctx.net, seed)
        for _, buffer in pairs(chat.get(ctx.net).buffers) do
            if starts(buffer.name) then table.insert(t, buffer.name) end
        end
        return t
    end
    return cmd
end

local function who_command(chat)
    local cmd = chat.command('who', '$g $R', 'mask [options]',
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
        task.spawn('who', {net = ctx.net, owner = chat.name}, who.run, mask, options ~= '' and options or nil)
    end)

    -- Tab on the options offers formats for what a WHO is mostly for:
    -- every field (bar the token and oplevel), who's who and addresses;
    -- and o, alone or with every field, for operators only. The address is asked for only while
    -- we're opered, as the server hides it from the rest, and the
    -- channel not for a channel's WHO, as it would be the same on every
    -- row. A server without WHOX takes o only after the mask 0.
    function cmd.complete(ctx, before, seed)
        local words = {}
        for word in before:gmatch '%g+' do table.insert(words, word) end
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
    return cmd
end

local function topic_command(chat)
    local cmd = chat.command('topic', '$T', '[text]', "Set the shown channel's topic, or clear it",
    function(ctx, text)
        local channel = modes.shown_channel(ctx)
        send.send(ctx.net, 'TOPIC', channel, text)
        chat.refetch_observed(ctx.net, channel)
    end)

    -- Tab with nothing typed yet offers the current topic, to edit
    function cmd.complete(ctx, before, seed)
        if before ~= '' or seed ~= '' then return nil end
        local irc = model(ctx.net)
        local channel = irc and ctx.target and irc_model.known_channel(irc, ctx.target)
        if channel and channel.topic and channel.topic ~= '' then
            return {channel.topic}
        end
    end
    return cmd
end

-- Open the buffer of each of a line's targets (a,b), without its
-- STATUSMSG prefix (@#chan)
local function open_targets(chat, net, targets)
    local irc = model(net)
    for target in targets:gmatch '[^,]+' do
        local _, name = target, target
        if irc then _, name = irc_model.split_statusmsg(irc, target) end
        chat.open(net, name)
    end
end

--- Chat's commands, made for chat.
---@param chat hub.Chat
function M.commands(chat)
    local list = {
        chat.command('talk', '$g', 'target', 'Talk to a channel or nick: opens a buffer, joins or monitors',
        function(ctx, target)
            chat.talk(ctx.net, target)
            bus.emit('chat.focus', {net = ctx.net, target = target})
        end),
        close_command(chat),
        -- each opens its targets' buffers, so the line shows there
        chat.command('msg', '$g $t', 'target text', 'Send a message', function(ctx, target, text)
            open_targets(chat, ctx.net, target)
            chat.say(ctx.net, target, text)
        end),
        chat.command('notice', '$g $t', 'target text', 'Send a notice', function(ctx, target, text)
            open_targets(chat, ctx.net, target)
            chat.notice(ctx.net, target, text)
        end),
        chat.command('cmsg', '$g $t', 'nick text',
            "Send a message to a nick, shown to them in the shown channel (channel-context)",
        function(ctx, nick, text)
            local channel = modes.shown_channel(ctx)
            local irc = model(ctx.net) --[[@as hub.Irc]]
            if irc_model.is_channel_name(irc, nick) then
                error('not a nick: ' .. nick, 0)
            end
            if not irc_model.get_channel(irc, channel) then
                error('not in ' .. channel, 0)
            end
            local tag = irc_model.channel_context_tag:sub(2)
            if not irc.caps_enabled['message-tags'] then
                error(ctx.net .. ' has not enabled message-tags, which client tags need', 0)
            elseif not irc_model.client_tag_allowed(irc, tag) then
                error(string.format('%s refuses the %s tag (CLIENTTAGDENY=%s)',
                    ctx.net, tag, tostring(irc.isupport.CLIENTTAGDENY)), 0)
            end
            send.send_tagged(ctx.net, {[irc_model.channel_context_tag] = channel}, 'PRIVMSG', nick, text)
        end),
        chat.command('ctcp', '$g $r', 'target request', 'Send a CTCP request', function(ctx, target, text)
            open_targets(chat, ctx.net, target)
            send.send(ctx.net, 'PRIVMSG', target, '\x01' .. text .. '\x01')
        end),
        chat.command('chaninfo', '$R', '[channel]',
            "Show a channel's topic, modes and members",
        function(ctx, target)
            if target == '' then target = ctx.target end
            local irc = model(ctx.net)
            if not (target and irc and irc_model.is_channel_name(irc, target)) then
                error('not a channel: ' .. tostring(target or 'no buffer'), 0)
            end
            chat.channel_info(ctx.net, target)
            bus.emit('chat.show_channel', {net = ctx.net, target = target})
        end),
        topic_command(chat),
        chat.command('list', '$R', '[pattern]',
            'List channels, optionally matching a pattern; without one, fetched only the first time',
        function(ctx, arg)
            -- the list view's refresh button fetches again
            if (arg and arg ~= '') or not chat.get(ctx.net).list_count then
                chat.list(ctx.net, arg)
            end
            bus.emit('chat.show_list', {net = ctx.net})
        end),
        who_command(chat),
        chat.command('stats', '$g $R', 'letter [server]', "STATS a letter, of a server or ours, shown as tables",
        function(ctx, letter, server)
            -- the server takes the first byte, and names it in the end
            if not letter:match '^%g$' then error('a STATS letter is one ASCII character: ' .. letter, 0) end
            if server:find ' ' then error('one server: ' .. server, 0) end
            task.spawn('stats', {net = ctx.net, owner = chat.name}, listing.stats, letter,
                server ~= '' and server or nil)
        end),
        chat.command('trace', '$R', '[target]', 'TRACE a server or nick, or ours, shown as tables',
        function(ctx, target)
            if target:find ' ' then error('one target: ' .. target, 0) end
            task.spawn('trace', {net = ctx.net, owner = chat.name}, listing.trace, target ~= '' and target or nil)
        end),
        chat.command('whois', '$g', 'nick', 'WHOIS a nick, shown in the detail pane', function(ctx, nick)
            chat.whois(ctx.net, nick)
        end),
        chat.command('wii', '$g', 'nick', 'WHOIS a nick on its server (with idle time)', function(ctx, nick)
            chat.whois(ctx.net, nick, true)
        end),
        chat.command('whowas', '$g $R', 'nick [count]', 'WHOWAS a nick, at most count entries',
        function(ctx, nick, count)
            local n
            if count ~= '' then
                n = math.tointeger(tonumber(count))
                if not n or n < 1 then error('count must be a positive number: ' .. count, 0) end
            end
            task.spawn('whowas', {net = ctx.net, owner = chat.name}, whowas, nick, n)
        end),
        chat.command('umode', '$r', 'modes', 'Change our user modes, e.g. +i-w', function(ctx, args)
            local irc = model(ctx.net)
            if not irc then error('not connected', 0) end
            local parts = {}
            for word in args:gmatch '%S+' do table.insert(parts, word) end
            send.send(ctx.net, 'MODE', irc.nick, table.unpack(parts))
        end),
    }
    for _, cmd in ipairs(modes.commands(chat)) do table.insert(list, cmd) end
    return list
end

return M
