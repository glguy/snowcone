-- Chat's commands: talking (/cmsg a private message shown in a channel),
-- buffers and channel information; the channel operator commands are in
-- chat/modes.lua.

local bus       <const> = require 'hub.runtime.bus'
local chat      <const> = require 'hub.features.chat'
local common    <const> = require 'hub.features.common'
local irc_model <const> = require 'hub.net.irc'
local modes     <const> = require 'hub.features.chat.modes'
local send      <const> = require 'hub.net.send'

local M = {}

local command <const> = common.net_command(chat.name)

local function model(net)
    local rec = HUB.state.nets[net]
    return rec and rec.irc
end

local function close_command()
    local cmd = command('close', '$R', '[target]',
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

local function topic_command()
    local cmd = command('topic', '$T', '[text]', "Set the shown channel's topic, or clear it",
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
local function open_targets(net, targets)
    local irc = model(net)
    for target in targets:gmatch '[^,]+' do
        local _, name = target, target
        if irc then _, name = irc_model.split_statusmsg(irc, target) end
        chat.open(net, name)
    end
end

M.commands = {
    command('talk', '$g', 'target', 'Talk to a channel or nick: opens a buffer, joins or monitors',
    function(ctx, target)
        chat.talk(ctx.net, target)
        bus.emit('chat.focus', {net = ctx.net, target = target})
    end),
    close_command(),
    -- each opens its targets' buffers, so the line shows there
    command('msg', '$a $t', 'target text', 'Send a message', function(ctx, target, text)
        open_targets(ctx.net, target)
        chat.say(ctx.net, target, text)
    end),
    command('notice', '$a $t', 'target text', 'Send a notice', function(ctx, target, text)
        open_targets(ctx.net, target)
        chat.notice(ctx.net, target, text)
    end),
    command('cmsg', '$a $t', 'nick text',
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
    command('ctcp', '$a $r', 'target request', 'Send a CTCP request', function(ctx, target, text)
        open_targets(ctx.net, target)
        send.send(ctx.net, 'PRIVMSG', target, '\x01' .. text .. '\x01')
    end),
    command('chaninfo', '$R', '[channel]',
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
    topic_command(),
}

return M
