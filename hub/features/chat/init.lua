-- Chat (from ircc's handlers/irc.lua, handlers/batch.lua,
-- handlers/commands.lua and utils/irc_registration.lua): buffers of
-- messages per network and target, mentions, history and the chat
-- commands.
--
-- state.features.chat[net] = {
--   buffers  [folded target] = {name, messages = OrderedMap, activity,
--            mention}; activity counts unseen messages
--   list     OrderedMap of /list results: {channel, users, topic}
-- }
--
-- Sending: replies to CTCP requests from staff, CHATHISTORY and MONITOR
-- for buffers, and what the commands ask for. PRIVMSG and NOTICE go out
-- only from commands and talk mode.

local bus        <const> = require 'hub.runtime.bus'
local common     <const> = require 'hub.features.common'
local ctcp       <const> = require 'hub.features.chat.ctcp'
local irc_model  <const> = require 'hub.net.irc'
local log        <const> = require 'hub.runtime.log'
local N          <const> = require 'hub.lib.numerics'
local OrderedMap <const> = require 'hub.lib.OrderedMap'
local send       <const> = require 'hub.net.send'
local task       <const> = require 'hub.runtime.task'
local whois      <const> = require 'hub.features.chat.whois'

local M = {}

M.name = 'chat'
M.buffer_size = 1000
M.list_size = 10000

--- WALLOPS and OPERWALL collect in this buffer of each network
M.wallops = '*wallops'

local function new_state()
    return {buffers = {}, list = OrderedMap.new(M.list_size)}
end

function M.get(net)
    return common.net_state(M.name, net, new_state)
end

local function enabled(net)
    return common.enabled(net, M.name)
end

local function query(net, ...)
    local ok, err = pcall(send.send, net, ...)
    if not ok then
        log.add_net(net, 'chat', '%s', err)
    end
end

local function model(net)
    local rec = HUB.state.nets[net]
    return rec and rec.irc
end

--- Fold a target with the network's casemapping.
function M.fold(net, target)
    local irc = model(net)
    if irc then
        return irc_model.fold(irc, target)
    end
    return snowcone.irccase(target)
end

-- Buffers =============================================================

--- Ask for the history of a buffer: what came before `before` (a server
--- time tag), or the latest.
local function request_history(net, name, before)
    local irc = model(net)
    if not (irc and irc_model.has_chathistory(irc)) then return end
    if HUB.state.nets[net].phase ~= 'connected' then return end
    local amount = M.buffer_size
    if irc.max_chat_history and irc.max_chat_history < amount then
        amount = irc.max_chat_history
    end
    if before then
        query(net, 'CHATHISTORY', 'BEFORE', name, 'timestamp=' .. before, amount)
    else
        query(net, 'CHATHISTORY', 'LATEST', name, '*', amount)
    end
end

--- A buffer, if it exists.
function M.buffer(net, target)
    return M.get(net).buffers[M.fold(net, target)]
end

--- A buffer, created (and its history requested) when missing.
---@param before string|nil server time of the message that opened it
function M.open(net, target, before)
    local C = M.get(net)
    local key = M.fold(net, target)
    local buffer = C.buffers[key]
    if buffer then
        buffer.name = target
        return buffer
    end
    buffer = {name = target, messages = OrderedMap.new(M.buffer_size), activity = 0, mention = false}
    C.buffers[key] = buffer
    if target ~= M.wallops then
        request_history(net, target, before)
    end
    bus.emit('chat.buffer', {net = net, target = target, opened = true})
    return buffer
end

--- Forget a buffer, and stop monitoring its nick.
function M.close(net, target)
    local C = M.get(net)
    local key = M.fold(net, target)
    local irc = model(net)
    if irc and irc_model.get_monitor(irc, target) then
        query(net, 'MONITOR', '-', target)
        irc_model.del_monitor(irc, target)
    end
    C.buffers[key] = nil
    bus.emit('chat.buffer', {net = net, target = target, opened = false})
end

--- Mark a buffer as seen.
function M.look(buffer)
    buffer.activity = 0
    buffer.mention = false
end

local function add(net, target, msg, mention, activity)
    local buffer = M.open(net, target, msg.tags and msg.tags.time)
    OrderedMap.insert(buffer.messages, true, msg)
    if mention then
        buffer.mention = true
    end
    if activity then
        buffer.activity = buffer.activity + 1
    end
    bus.emit('chat.message', {net = net, target = target, msg = msg, mention = mention, activity = activity})
end

-- Mentions ============================================================

--- Mention patterns (Lua patterns): the network's, else the global ones.
local function mention_patterns(net)
    local rec = HUB.state.nets[net]
    local own = rec and rec.cfg.mention
    if own and own.patterns then return own.patterns end
    local global = HUB.state.config and HUB.state.config.mention
    return global and global.patterns or {}
end

-- Where a message belongs: channel messages in the channel, private ones
-- in a buffer named for the other side
local function route_chat(net, irc, target, text, msg)
    local buffer_target, mention
    local nick = msg.nick

    if irc_model.is_channel_name(irc, target) then
        buffer_target = target
        for _, pattern in ipairs(mention_patterns(net)) do
            local ok, found = pcall(string.find, text, pattern)
            if ok and found then
                mention = true
                break
            end
        end
    elseif nick and nick == irc.nick then
        -- something I sent, relayed by a bouncer or to myself
        buffer_target = target
    elseif target == irc.nick then
        buffer_target = nick
        mention = true
    end

    -- nil for a message from a server
    if buffer_target then
        add(net, buffer_target, msg, mention or false, true)
    end
end

-- Add a membership change to the buffers of the channels it concerns
local function to_channels(net, channels, msg)
    for _, name in ipairs(channels) do
        add(net, name, msg, false, false)
    end
end

local function to_user(net, nick, msg)
    if nick and M.buffer(net, nick) then
        add(net, nick, msg, false, false)
    end
end

local function channels_with(irc, nick)
    local key = irc_model.fold(irc, nick)
    local names = {}
    for _, channel in pairs(irc.channels) do
        if channel.members[key] then
            table.insert(names, channel.name)
        end
    end
    return names
end

-- Inbound =============================================================

local H = {}

function H.PRIVMSG(net, irc, msg)
    local prefix, target = irc_model.split_statusmsg(irc, msg[1])
    local text = msg[2]
    msg.statusmsg = prefix

    -- answer only targeted CTCP requests from staff
    local name, args = text:match '^\x01([^\x01 ]+) ?([^\x01]*)\x01?$'
    if name and target == irc.nick and msg.tags['solanum.chat/oper'] and msg.nick then
        name = name:upper()
        local h = ctcp[name]
        if h then
            local response = h(args)
            if response then
                query(net, 'NOTICE', msg.nick, '\x01' .. name .. ' ' .. response .. '\x01')
            end
        end
    end

    route_chat(net, irc, target, text, msg)
end

function H.NOTICE(net, irc, msg)
    -- server notices belong to the snotice feature
    if msg[1] == '*' then return end
    local prefix, target = irc_model.split_statusmsg(irc, msg[1])
    msg.statusmsg = prefix
    route_chat(net, irc, target, msg[2], msg)
end

function H.WALLOPS(net, _, msg)
    add(net, M.wallops, msg, false, true)
end
H.OPERWALL = H.WALLOPS

function H.JOIN(net, _, msg) add(net, msg[1], msg, false, false) end
function H.PART(net, _, msg) add(net, msg[1], msg, false, false) end
function H.KICK(net, _, msg) add(net, msg[1], msg, false, false) end
function H.TOPIC(net, _, msg) add(net, msg[1], msg, false, false) end

function H.MODE(net, irc, msg)
    if irc_model.is_channel_name(irc, msg[1]) then
        add(net, msg[1], msg, false, false)
    end
end

-- QUIT and NICK carry the channels the user was in (net/handlers.lua)
function H.QUIT(net, _, msg)
    to_channels(net, msg.channels or {}, msg)
    to_user(net, msg.nick, msg)
end

function H.NICK(net, _, msg)
    to_channels(net, msg.channels or {}, msg)
    local C = M.get(net)
    local old = msg.nick and M.fold(net, msg.nick)
    local buffer = old and C.buffers[old]
    if buffer then
        local new = M.fold(net, msg[1])
        buffer.name = msg[1]
        if new ~= old then
            C.buffers[old] = nil
            C.buffers[new] = buffer
        end
        add(net, msg[1], msg, false, false)
    end
end

local function user_change(net, irc, msg)
    if not msg.nick then return end
    to_channels(net, channels_with(irc, msg.nick), msg)
    to_user(net, msg.nick, msg)
end
H.ACCOUNT = user_change
H.CHGHOST = user_change

-- "<client> <channel> <client count> :<topic>" (from /list)
H[N.RPL_LIST] = function(net, _, msg)
    local C = M.get(net)
    if C.listing then
        OrderedMap.insert(C.list, msg[2], {
            time = msg.time,
            timestamp = msg.timestamp,
            channel = msg[2],
            users = math.tointeger(msg[3]),
            topic = msg[4] or '',
        })
    end
end

H[N.RPL_LISTEND] = function(net)
    M.get(net).listing = nil
end

local function on_message(ev)
    if not enabled(ev.net) then return end
    local h = H[ev.msg.command]
    local irc = model(ev.net)
    if h and irc then
        h(ev.net, irc, ev.msg)
    end
end

-- Our own messages, shown where they went
local function on_sent(ev)
    if not enabled(ev.net) then return end
    local msg = ev.msg
    if msg.command ~= 'PRIVMSG' and msg.command ~= 'NOTICE' then return end
    local irc = model(ev.net)
    if not irc or not msg[1] then return end
    for target in msg[1]:gmatch '[^,]+' do
        local prefix, name = irc_model.split_statusmsg(irc, target)
        if M.buffer(ev.net, name) then
            local copy = msg
            if prefix then
                copy = {}
                for k, v in pairs(msg) do copy[k] = v end
                copy.statusmsg = prefix
            end
            local buffer = M.buffer(ev.net, name)
            OrderedMap.insert(buffer.messages, true, copy)
        end
    end
end

-- Chat history arrives in batches
local function on_batch(ev)
    if not enabled(ev.net) or ev.type ~= 'chathistory' then return end
    local irc = model(ev.net)
    local buffer = M.buffer(ev.net, ev.params[1] or '')
    if not (irc and buffer) then return end
    for _, msg in ipairs(ev.messages) do
        if msg.command == 'PRIVMSG' or msg.command == 'NOTICE' then
            msg.statusmsg = irc_model.split_statusmsg(irc, msg[1])
        end
        OrderedMap.insert(buffer.messages, true, msg)
    end
end

-- After registration: history for the open buffers, and MONITOR for the
-- private ones (from ircc's irc_registration)
local function on_registered(ev)
    local net = ev.net
    if not enabled(net) then return end
    local irc = model(net)
    local C = M.get(net)
    for key, buffer in pairs(C.buffers) do
        if key ~= M.fold(net, M.wallops) then
            local last = OrderedMap.lookup(buffer.messages, true)
            local before = last and last.tags and last.tags.time
            -- LATEST since the last message we have
            if irc_model.has_chathistory(irc) then
                local amount = M.buffer_size
                if irc.max_chat_history and irc.max_chat_history < amount then
                    amount = irc.max_chat_history
                end
                query(net, 'CHATHISTORY', 'LATEST', buffer.name, before and 'timestamp=' .. before or '*', amount)
            end
        end
    end

    if irc_model.has_monitor(irc) then
        local nicks, size = {}, 0
        for key, buffer in pairs(C.buffers) do
            if key ~= M.fold(net, M.wallops) and not irc_model.is_channel_name(irc, buffer.name) then
                table.insert(nicks, buffer.name)
                size = size + #buffer.name + 1
                if size > 400 then
                    query(net, 'MONITOR', '+', table.concat(nicks, ','))
                    nicks, size = {}, 0
                end
            end
        end
        if #nicks > 0 then
            query(net, 'MONITOR', '+', table.concat(nicks, ','))
        end
    end
end

function M.subscribe(sub)
    sub.on('irc.message', on_message)
    sub.on('irc.sent', on_sent)
    sub.on('irc.batch', on_batch)
    sub.on('net.registered', on_registered)
    sub.on('net.removed', function(ev) common.drop_state(M.name, ev.net) end)
end

-- Talking =============================================================

--- Open a buffer to talk in: join a channel we aren't in, monitor a nick.
function M.talk(net, target)
    local irc = model(net)
    M.open(net, target)
    if irc and HUB.state.nets[net].phase == 'connected' then
        if irc_model.is_channel_name(irc, target) then
            if not irc_model.get_channel(irc, target) then
                query(net, 'JOIN', target)
            end
        elseif irc_model.has_monitor(irc) and not irc_model.get_monitor(irc, target) then
            query(net, 'MONITOR', '+', target)
        end
    end
end

--- Send a message to a target.
function M.say(net, target, text)
    send.send(net, 'PRIVMSG', target, text)
end

--- Fetch the channel list.
function M.list(net, arg)
    local C = M.get(net)
    OrderedMap.reset(C.list)
    C.listing = true
    if arg and arg ~= '' then
        send.send(net, 'LIST', arg)
    else
        send.send(net, 'LIST')
    end
end

-- Commands ============================================================

local function chat_command(name, spec, help, fn)
    return {name = name, spec = spec, scope = 'net', feature = M.name, help = help, fn = fn}
end

M.commands = {
    chat_command('talk', '$g', 'Talk to a channel or nick: opens a buffer, joins or monitors', function(ctx, target)
        M.talk(ctx.net, target)
        bus.emit('chat.focus', {net = ctx.net, target = target})
    end),
    chat_command('close', '$R', 'Close a buffer (the shown one by default)', function(ctx, target)
        if target == '' then
            target = ctx.target
        end
        if not target then
            error('no buffer to close', 0)
        end
        M.close(ctx.net, target)
    end),
    chat_command('msg', '$g $r', 'Send a message', function(ctx, target, text)
        M.say(ctx.net, target, text)
    end),
    chat_command('notice', '$g $r', 'Send a notice', function(ctx, target, text)
        send.send(ctx.net, 'NOTICE', target, text)
    end),
    chat_command('ctcp', '$g $r', 'Send a CTCP request', function(ctx, target, text)
        send.send(ctx.net, 'PRIVMSG', target, '\x01' .. text .. '\x01')
    end),
    chat_command('list', '$R', 'List channels, optionally matching a pattern', function(ctx, arg)
        M.list(ctx.net, arg)
        bus.emit('chat.show_list', {net = ctx.net})
    end),
    chat_command('whois', '$g', 'WHOIS a nick, summarised in the status log', function(ctx, nick)
        task.spawn('whois', {net = ctx.net, owner = M.name}, whois, nick, false)
    end),
    chat_command('wii', '$g', 'WHOIS a nick on its server (with idle time)', function(ctx, nick)
        task.spawn('whois', {net = ctx.net, owner = M.name}, whois, nick, true)
    end),
    chat_command('whowas', '$g', 'WHOWAS a nick', function(ctx, nick)
        send.send(ctx.net, 'WHOWAS', nick)
    end),
    chat_command('umode', '$r', 'Change our user modes, e.g. +i-w', function(ctx, args)
        local irc = model(ctx.net)
        if not irc then error('not connected', 0) end
        local parts = {}
        for word in args:gmatch '%S+' do table.insert(parts, word) end
        send.send(ctx.net, 'MODE', irc.nick, table.unpack(parts))
    end),
}

return M
