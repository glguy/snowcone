-- Chat: buffers of messages per network and target, mentions, history
-- and the chat commands.
--
-- state.features.chat[net] = {
--   buffers  [folded target] = {name, messages = OrderedMap, activity,
--            mention}; activity counts unseen messages, and messages
--            are keyed by their msgid tag when they have one
--   list     OrderedMap of /list results: {channel, users, topic}
--   pending  [label] = {[folded target] = {msg, buffer}}: our labeled
--            PRIVMSG and NOTICE lines awaiting the server's reply
-- }
--
-- Sending: replies to CTCP requests from staff, CHATHISTORY and MONITOR
-- for buffers, and what the commands ask for. PRIVMSG and NOTICE go out
-- only from commands and talk mode.
--
-- Receipt: with labeled-response (net/send.lua labels chat lines) our
-- message in a buffer has msg.receipt: 'awaiting' until the reply, then
-- 'received' on its echo (whose msgid and time it takes) or ACK,
-- 'rejected' on an error (msg.rejection holds its text), or 'unknown' if
-- the reply never settled it. The echo itself isn't shown again.

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
local whowas     <const> = require 'hub.features.chat.whowas'

local M = {}

M.name = 'chat'
M.buffer_size = 1000
M.list_size = 10000

--- WALLOPS and OPERWALL collect in this buffer of each network
M.wallops = '*wallops'

--- A network's chat, state.features.chat[net].
---@class hub.ChatState
---@field buffers table<string, hub.ChatBuffer> by folded target
---@field list hub.OrderedMap the last LIST reply
---@field listing true|nil while LIST replies arrive
---@field pending table<string, table<string, {msg: hub.Message, buffer: hub.ChatBuffer|nil}>>
--- by label, then by folded target; for the current connection

---@return hub.ChatState
local function new_state()
    return {buffers = {}, list = OrderedMap.new(M.list_size), pending = {}}
end

---@param net string
---@return hub.ChatState
function M.get(net)
    local C = common.net_state(M.name, net, new_state)
    -- added after state from earlier code
    C.pending = C.pending or {}
    return C
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

---@class hub.ChatBuffer
---@field name string the target, as last seen
---@field messages hub.OrderedMap keyed by msgid, when there is one
---@field activity integer messages since it was last seen
---@field mention boolean

--- A buffer, created (and its history requested) when missing.
---@param net string
---@param target string
---@param before string|nil server time of the message that opened it
---@return hub.ChatBuffer
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

--- The buffer to move to from the one with folded name `from`: one with
--- a mention, else one with activity, else (unless `active`) any; among
--- equals the next by folded name after `from`, wrapping round, and
--- `from` itself last. Nil when there is none.
function M.next_buffer(net, from, active)
    local function rank(buffer)
        if buffer.activity == 0 then return 0 end
        return buffer.mention and 2 or 1
    end
    -- 0 after `from`, 1 wrapped round before it, 2 for `from` itself
    local function lap(key)
        return key > from and 0 or key < from and 1 or 2
    end
    local best, best_key
    for key, buffer in pairs(M.get(net).buffers) do
        if not active or buffer.activity > 0 then
            local better = not best
                or rank(buffer) > rank(best)
                or rank(buffer) == rank(best)
                   and (lap(key) < lap(best_key)
                        or lap(key) == lap(best_key) and key < best_key)
            if better then
                best, best_key = buffer, key
            end
        end
    end
    return best
end

--- Mark a buffer as seen.
function M.look(buffer)
    buffer.activity = 0
    buffer.mention = false
end

local function msgid(msg)
    return msg.tags and msg.tags.msgid
end

-- A message is keyed by its msgid; ours, until its echo brings one, by
-- itself. Others are reached only by iteration.
local function insert(buffer, msg)
    local key = msgid(msg)
    if key == nil and msg.receipt == 'awaiting' then key = msg end
    OrderedMap.insert(buffer.messages, key, msg)
end

--- The message with a msgid in a buffer, while the buffer holds it.
---@param buffer hub.ChatBuffer
---@param id string
---@return hub.Message|nil
function M.find(buffer, id)
    return OrderedMap.lookup(buffer.messages, id)
end

--- The newest message in a buffer.
---@param buffer hub.ChatBuffer
---@return hub.Message|nil
function M.newest(buffer)
    return (OrderedMap.get(buffer.messages, OrderedMap.last(buffer.messages)))
end

local function add(net, target, msg, mention, activity)
    local buffer = M.open(net, target, msg.tags and msg.tags.time)
    local id = msgid(msg)
    -- a message the buffer already has, from history or a bouncer
    if id and M.find(buffer, id) then return end
    insert(buffer, msg)
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
    elseif irc_model.is_me(irc, nick) then
        -- something I sent, relayed by a bouncer or to myself
        buffer_target = target
    elseif irc_model.is_me(irc, target) then
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
    if name and irc_model.is_me(irc, target) and msg.tags['solanum.chat/oper'] and msg.nick then
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
        if new ~= old and C.buffers[new] then
            -- a buffer for the new nick exists: keep both, unrenamed
            insert(buffer, msg)
            return
        end
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

-- Receipt ============================================================

-- An echo is the message as the server delivered it, perhaps edited
-- (colors stripped, say): our copy takes its parameters and tags, keeping
-- its own source so it is still drawn as ours
local function received(entry, echo)
    local msg = entry.msg
    if msg.receipt ~= 'awaiting' then return end
    msg.receipt = 'received'
    if not echo then return end
    for i = 1, math.max(#msg, #echo) do
        msg[i] = echo[i]
    end
    msg.tags = echo.tags
    local id = msgid(echo)
    if id and entry.buffer then
        OrderedMap.rekey(entry.buffer.messages, msg, id)
    end
end

local function rejected(entry, reason)
    local msg = entry.msg
    if msg.receipt ~= 'awaiting' then return end
    msg.receipt = 'rejected'
    msg.rejection = reason
end

-- The reply is over: what it didn't settle stays unknown
local function settle(C, label)
    for _, entry in pairs(C.pending[label]) do
        if entry.msg.receipt == 'awaiting' then
            entry.msg.receipt = 'unknown'
        end
    end
    C.pending[label] = nil
end

-- A message of the reply to one of our labeled lines: an echo, ACK or
-- error, alone or in a labeled batch. True for an echo, which is shown
-- already.
local function on_reply(net, irc, msg)
    local C = M.get(net)
    local label, batched = msg.tags.label, false
    if label == nil then
        local batch = irc.batches[msg.tags.batch]
        label, batched = batch and batch.label, true
    end
    local entries = label and C.pending[label]
    if not entries then return false end

    local command = msg.command
    local echo = false
    if command == 'BATCH' then
        return false -- its end settles the reply (on_batch)
    elseif (command == 'PRIVMSG' or command == 'NOTICE') and irc_model.is_me(irc, msg.nick) then
        echo = true
        local entry = msg[1] and entries[M.fold(net, msg[1])]
        if entry then received(entry, msg) end
    elseif command == 'ACK' then
        for _, entry in pairs(entries) do received(entry) end
    else
        -- an error about one target (ERR_NOSUCHNICK), or about them all
        local entry = msg[2] and entries[M.fold(net, msg[2])]
        local reason = msg[#msg]
        if entry then
            rejected(entry, reason)
        else
            for _, each in pairs(entries) do rejected(each, reason) end
        end
    end
    if not batched then
        settle(C, label)
    end
    return echo
end

local function on_message(ev)
    if not enabled(ev.net) then return end
    local irc = model(ev.net)
    if not irc then return end
    if on_reply(ev.net, irc, ev.msg) then return end
    local h = H[ev.msg.command]
    if h then
        h(ev.net, irc, ev.msg)
    end
end

-- Our own messages, shown where they went; a labeled one awaits its reply
local function on_sent(ev)
    if not enabled(ev.net) then return end
    local msg = ev.msg
    if msg.command ~= 'PRIVMSG' and msg.command ~= 'NOTICE' then return end
    local irc = model(ev.net)
    if not irc or not msg[1] then return end
    local label = msg.tags.label
    local entries = {}
    local targets = {}
    for target in msg[1]:gmatch '[^,]+' do table.insert(targets, target) end
    for _, target in ipairs(targets) do
        local prefix, name = irc_model.split_statusmsg(irc, target)
        local buffer = M.buffer(ev.net, name)
        local copy = msg
        -- the console keeps the line as sent, and each target's echo
        -- brings its own msgid and text
        if prefix or label or #targets > 1 then
            copy = {}
            for k, v in pairs(msg) do copy[k] = v end
            copy.tags = {}
            for k, v in pairs(msg.tags) do copy.tags[k] = v end
            copy.statusmsg = prefix
        end
        if label then
            copy.receipt = 'awaiting'
            -- without a buffer it is still awaited, so its echo is known
            entries[M.fold(ev.net, target)] = {msg = copy, buffer = buffer}
        end
        if buffer then
            insert(buffer, copy)
        end
    end
    if label then
        M.get(ev.net).pending[label] = entries
    end
end

-- Chat history arrives in batches, and so does a reply to a line with
-- several targets
local function on_batch(ev)
    if not enabled(ev.net) then return end
    local C = M.get(ev.net)
    if ev.label and C.pending[ev.label] then
        settle(C, ev.label)
    end
    if ev.type ~= 'chathistory' then return end
    local irc = model(ev.net)
    local buffer = M.buffer(ev.net, ev.params[1] or '')
    if not (irc and buffer) then return end
    for _, msg in ipairs(ev.messages) do
        if msg.command == 'PRIVMSG' or msg.command == 'NOTICE' then
            msg.statusmsg = irc_model.split_statusmsg(irc, msg[1])
        end
    end
    local rec = HUB.state.nets[ev.net]
    M.merge(buffer, ev.messages, rec and rec.registered_at)
end

-- Identity of a message, to spot one that history repeats. The server's
-- time is compared only as text.
local function message_key(msg)
    local id = msgid(msg)
    if id then return 'id ' .. id end
    local tags = msg.tags or {}
    return table.concat({tags.time or '', tostring(msg.source), tostring(msg.command), table.concat(msg, ' ')}, '\0')
end

--- Merge history into a buffer. Server times are never compared: the
--- history goes, in the server's order, before the messages that arrived
--- on the current connection (those received since `since`, its
--- registration), which puts it before everything when a buffer opens and
--- between the old and new messages after a reconnect. Messages already
--- there are skipped.
---@param buffer hub.ChatBuffer
---@param messages hub.Message[]
---@param since number|nil clock.now() at registration
function M.merge(buffer, messages, since)
    local older, newer, seen = {}, {}, {}
    for msg in OrderedMap.reveach(buffer.messages) do
        local ts = msg.timestamp
        table.insert(since and ts and ts >= since and newer or older, msg)
        seen[message_key(msg)] = true
    end
    for _, msg in ipairs(messages) do
        local key = message_key(msg)
        if not seen[key] then
            seen[key] = true
            -- drawn as old, not as just received
            msg.timestamp = nil
            table.insert(older, msg)
        end
    end
    OrderedMap.reset(buffer.messages)
    for _, list in ipairs {older, newer} do
        for _, msg in ipairs(list) do
            insert(buffer, msg)
        end
    end
end

-- After registration: history for the open buffers, and MONITOR for the
-- private ones
local function on_registered(ev)
    local net = ev.net
    if not enabled(net) then return end
    local irc = model(net)
    ---@cast irc -nil registered, so connected
    local C = M.get(net)
    for key, buffer in pairs(C.buffers) do
        if key ~= M.fold(net, M.wallops) then
            local last = M.newest(buffer)
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
    -- labels start again on the next connection
    sub.on('net.closed', function(ev)
        if not enabled(ev.net) then return end
        local C = M.get(ev.net)
        for label in pairs(C.pending) do settle(C, label) end
    end)
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

-- Channels ============================================================

--- Ask for what a channel's information needs and the server didn't send
--- on join: its modes and creation time (MODE), unless they are known.
function M.channel_info(net, name)
    local irc = model(net)
    local channel = irc and irc_model.get_channel(irc, name)
    if channel and not channel.modes then
        query(net, 'MODE', name)
    end
end

--- Ask again for a channel's modes and creation time.
function M.refresh_modes(net, name)
    query(net, 'MODE', name)
end

--- Fetch a list mode of a channel, such as its bans (b) or quiets (q).
function M.fetch_list(net, name, mode)
    query(net, 'MODE', name, '+' .. mode)
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

local function chat_command(name, spec, usage, help, fn)
    return {name = name, spec = spec, usage = usage, scope = 'net', feature = M.name, help = help, fn = fn}
end

M.commands = {
    chat_command('talk', '$g', 'target', 'Talk to a channel or nick: opens a buffer, joins or monitors',
    function(ctx, target)
        M.talk(ctx.net, target)
        bus.emit('chat.focus', {net = ctx.net, target = target})
    end),
    chat_command('close', '$R', '[target]', 'Close a buffer, the shown one by default', function(ctx, target)
        if target == '' then
            target = ctx.target
        end
        if not target then
            error('no buffer to close', 0)
        end
        M.close(ctx.net, target)
    end),
    chat_command('msg', '$g $r', 'target text', 'Send a message', function(ctx, target, text)
        M.say(ctx.net, target, text)
    end),
    chat_command('notice', '$g $r', 'target text', 'Send a notice', function(ctx, target, text)
        send.send(ctx.net, 'NOTICE', target, text)
    end),
    chat_command('ctcp', '$g $r', 'target request', 'Send a CTCP request', function(ctx, target, text)
        send.send(ctx.net, 'PRIVMSG', target, '\x01' .. text .. '\x01')
    end),
    chat_command('chaninfo', '$R', '[channel]', "Show a channel's topic, modes and members, the shown one by default",
    function(ctx, target)
        if target == '' then target = ctx.target end
        local irc = model(ctx.net)
        if not (target and irc and irc_model.is_channel_name(irc, target)) then
            error('not a channel: ' .. tostring(target or 'no buffer'), 0)
        end
        M.channel_info(ctx.net, target)
        bus.emit('chat.show_channel', {net = ctx.net, target = target})
    end),
    chat_command('list', '$R', '[pattern]', 'List channels, optionally matching a pattern', function(ctx, arg)
        M.list(ctx.net, arg)
        bus.emit('chat.show_list', {net = ctx.net})
    end),
    chat_command('whois', '$g', 'nick', 'WHOIS a nick, shown in the detail pane', function(ctx, nick)
        task.spawn('whois', {net = ctx.net, owner = M.name}, whois, nick, false)
    end),
    chat_command('wii', '$g', 'nick', 'WHOIS a nick on its server (with idle time)', function(ctx, nick)
        task.spawn('whois', {net = ctx.net, owner = M.name}, whois, nick, true)
    end),
    chat_command('whowas', '$g $R', 'nick [count]', 'WHOWAS a nick, at most count entries', function(ctx, nick, count)
        local n
        if count ~= '' then
            n = math.tointeger(tonumber(count))
            if not n or n < 1 then error('count must be a positive number: ' .. count, 0) end
        end
        task.spawn('whowas', {net = ctx.net, owner = M.name}, whowas, nick, n)
    end),
    chat_command('umode', '$r', 'modes', 'Change our user modes, e.g. +i-w', function(ctx, args)
        local irc = model(ctx.net)
        if not irc then error('not connected', 0) end
        local parts = {}
        for word in args:gmatch '%S+' do table.insert(parts, word) end
        send.send(ctx.net, 'MODE', irc.nick, table.unpack(parts))
    end),
}

return M
