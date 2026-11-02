-- Chat's commands: talking (/cmsg a private message shown in a channel),
-- buffers, channel information, WHOIS and WHOWAS, and our user modes; the
-- channel operator commands are in chat/modes.lua. Chat requires this module, so it passes itself in.

local bus       <const> = require 'hub.runtime.bus'
local irc_model <const> = require 'hub.net.irc'
local modes     <const> = require 'hub.features.chat.modes'
local send      <const> = require 'hub.net.send'
local task      <const> = require 'hub.runtime.task'
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
        for _, buffer in pairs(chat.get(ctx.net).buffers) do
            if buffer.name:sub(1, #seed) == seed then table.insert(t, buffer.name) end
        end
        return t
    end
    return cmd
end

local function topic_command(chat)
    local cmd = chat.command('topic', '$R', '[text]', "Set the shown channel's topic, or clear it",
    function(ctx, text)
        send.send(ctx.net, 'TOPIC', modes.shown_channel(ctx), text)
    end)

    -- Tab with nothing typed yet offers the current topic, to edit
    function cmd.complete(ctx, before, seed)
        if before ~= '' or seed ~= '' then return nil end
        local irc = model(ctx.net)
        local channel = irc and ctx.target and irc_model.get_channel(irc, ctx.target)
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
        chat.command('msg', '$g $r', 'target text', 'Send a message', function(ctx, target, text)
            open_targets(chat, ctx.net, target)
            chat.say(ctx.net, target, text)
        end),
        chat.command('notice', '$g $r', 'target text', 'Send a notice', function(ctx, target, text)
            open_targets(chat, ctx.net, target)
            chat.notice(ctx.net, target, text)
        end),
        chat.command('cmsg', '$g $r', 'nick text',
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
            send.send(ctx.net, 'PRIVMSG', target, '\x01' .. text .. '\x01')
        end),
        chat.command('chaninfo', '$R', '[channel]',
            "Show a channel's topic, modes and members, the shown one by default",
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
        chat.command('list', '$R', '[pattern]', 'List channels, optionally matching a pattern', function(ctx, arg)
            chat.list(ctx.net, arg)
            bus.emit('chat.show_list', {net = ctx.net})
        end),
        chat.command('whois', '$g', 'nick', 'WHOIS a nick, shown in the detail pane; !nick is an operspy WHOIS', function(ctx, nick)
            chat.whois(ctx.net, nick)
        end),
        chat.command('wii', '$g', 'nick', 'WHOIS a nick on its server (with idle time); !nick is an operspy WHOIS', function(ctx, nick)
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
