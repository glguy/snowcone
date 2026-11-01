-- Chat: buffers of messages per network and target, mentions, history
-- and the chat commands.
--
-- state.features.chat[net] = {
--   buffers  [folded target] = {name, messages = OrderedMap, activity,
--            mention, typing}; activity counts unseen messages, messages
--            are keyed by their msgid tag when they have one, and typing
--            holds who is typing there (chat/typing.lua)
--   list     OrderedMap of /list results: {channel, users, topic}
--   pending  [label] = {[folded target] = {msg, buffer}}: our labeled
--            PRIVMSG and NOTICE lines awaiting the server's reply
--            (chat/receipt.lua)
--   closing  [folded channel] = true: channels /close parted, whose buffer
--            goes when our PART comes back
--   composing what we are writing and where, for our typing notices
--            (chat/typing.lua)
-- }
--
-- Sending: replies to CTCP requests from staff, CHATHISTORY (history.lua)
-- and MONITOR for buffers, our typing (TAGMSG, chat/typing.lua), and what
-- the commands ask for. PRIVMSG and NOTICE go out only from commands and
-- talk mode. Bans, quiets and kicks
-- go out at once, without staging: they reach one channel and are easily
-- undone.
--
-- Our own PRIVMSG and NOTICE lines are shown from irc.sent, and with
-- labeled-response await the server's reply (chat/receipt.lua).

local ban_mask   <const> = require 'hub.features.chat.masks'
local bus        <const> = require 'hub.runtime.bus'
local common     <const> = require 'hub.features.common'
local ctcp       <const> = require 'hub.features.chat.ctcp'
local history    <const> = require 'hub.features.chat.history'
local irc_model  <const> = require 'hub.net.irc'
local log        <const> = require 'hub.runtime.log'
local lookup     <const> = require 'hub.features.lookup'
local N          <const> = require 'hub.lib.numerics'
local OrderedMap <const> = require 'hub.lib.OrderedMap'
local receipt    <const> = require 'hub.features.chat.receipt'
local send       <const> = require 'hub.net.send'
local task       <const> = require 'hub.runtime.task'
local typing     <const> = require 'hub.features.chat.typing'
local whois      <const> = require 'hub.features.chat.whois'
local whowas     <const> = require 'hub.features.chat.whowas'

local M = {}

M.name = 'chat'
M.buffer_size = 1000
M.list_size = 10000

--- WALLOPS and OPERWALL collect in this buffer of each network
M.wallops = '*wallops'

--- What chat's parts (chat/typing.lua, history.lua, receipt.lua) use of
--- chat, which they are passed since it requires them.
---@class hub.ChatLookup
---@field wallops string
---@field buffer_size integer
---@field get fun(net: string): hub.ChatState
---@field fold fun(net: string, target: string): string
---@field buffer fun(net: string, target: string): hub.ChatBuffer|nil
---@field insert fun(buffer: hub.ChatBuffer, msg: hub.Message)
---@field newest fun(buffer: hub.ChatBuffer): hub.Message|nil

--- A network's chat, state.features.chat[net].
---@class hub.ChatState
---@field buffers table<string, hub.ChatBuffer> by folded target
---@field list hub.OrderedMap the last LIST reply
---@field listing true|nil while LIST replies arrive
---@field pending table<string, table<string, {msg: hub.Message, buffer: hub.ChatBuffer|nil}>>
--- by label, then by folded target; for the current connection
---@field closing table<string, true> channels /close parted, by folded name;
--- for the current connection
---@field composing hub.ChatComposing|nil what we are writing and where

---@return hub.ChatState
local function new_state()
    return {buffers = {}, list = OrderedMap.new(M.list_size), pending = {}, closing = {}}
end

---@param net string
---@return hub.ChatState
function M.get(net)
    local C = common.net_state(M.name, net, new_state)
    -- added after state from earlier code
    C.pending = C.pending or {}
    C.closing = C.closing or {}
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

--- A buffer, if it exists.
function M.buffer(net, target)
    return M.get(net).buffers[M.fold(net, target)]
end

---@class hub.ChatBuffer
---@field name string the target, as last seen
---@field messages hub.OrderedMap keyed by msgid, when there is one
---@field activity integer messages since it was last seen
---@field mention boolean
---@field typing table<string, hub.ChatTyping>|nil by folded nick; nil in
--- buffers from before typing was tracked (chat/typing.lua)

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
        -- what came before the message that opened it, or the latest
        history.request(M, net, target, before and 'BEFORE' or 'LATEST', before)
    end
    bus.emit('chat.buffer', {net = net, target = target, opened = true})
    return buffer
end

local function drop(net, key, target)
    M.get(net).buffers[key] = nil
    bus.emit('chat.buffer', {net = net, target = target, opened = false})
end

--- Forget a buffer: part its channel if we are in it, and stop
--- monitoring its nick.
function M.close(net, target)
    local C = M.get(net)
    local key = M.fold(net, target)
    local irc = model(net)
    if irc and irc_model.get_channel(irc, target) then
        -- our PART coming back would reopen the buffer, and so would a
        -- message before it: H.PART drops the buffer again
        query(net, 'PART', target)
        C.closing[key] = true
    end
    if irc and irc_model.get_monitor(irc, target) then
        query(net, 'MONITOR', '-', target)
        irc_model.del_monitor(irc, target)
    end
    drop(net, key, target)
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
M.insert = insert -- for chat/history.lua and receipt.lua

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

-- Typing ============================================================

--- Seconds a typing entry lasts without being refreshed, by state.
M.typing_timeout = typing.timeout

--- Who is typing in a buffer, the most recent change first.
---@param net string
---@param buffer hub.ChatBuffer
---@return hub.ChatTyping[]
function M.typing(net, buffer)
    return typing.list(M, net, buffer)
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

function H.JOIN(net, irc, msg)
    if irc_model.is_me(irc, msg.nick) then
        M.get(net).closing[M.fold(net, msg[1])] = nil
    end
    add(net, msg[1], msg, false, false)
end

function H.PART(net, irc, msg)
    local C = M.get(net)
    local key = M.fold(net, msg[1])
    if irc_model.is_me(irc, msg.nick) and C.closing[key] then
        C.closing[key] = nil
        local buffer = C.buffers[key]
        if buffer then drop(net, key, buffer.name) end
        return
    end
    add(net, msg[1], msg, false, false)
end

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

local function on_message(ev)
    if not enabled(ev.net) then return end
    local irc = model(ev.net)
    if not irc then return end
    if receipt.on_reply(M, ev.net, irc, ev.msg) then return end
    -- first, while the buffers are as they were before the message
    typing.handle(M, ev.net, irc, ev.msg)
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
    if not irc then return end
    typing.on_sent(M, ev.net, msg)
    receipt.on_sent(M, ev.net, irc, msg)
end

-- Chat history arrives in batches, and so does a reply to a line with
-- several targets
local function on_batch(ev)
    if not enabled(ev.net) then return end
    receipt.on_batch_end(M, ev.net, ev.label)
    if ev.type ~= 'chathistory' then return end
    history.on_batch(M, ev)
end

-- After registration: history for the open buffers, and MONITOR for the
-- private ones
local function on_registered(ev)
    local net = ev.net
    if not enabled(net) then return end
    local irc = model(net)
    ---@cast irc -nil registered, so connected
    local C = M.get(net)
    history.after_registration(M, net)

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
        receipt.settle_all(C)
        typing.reset(C)
        C.closing = {}
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

--- Send a notice to a target.
function M.notice(net, target, text)
    send.send(net, 'NOTICE', target, text)
end

--- Send an action (CTCP ACTION, /me in other clients) to a target.
function M.action(net, target, text)
    send.send(net, 'PRIVMSG', target, '\x01ACTION ' .. text .. '\x01')
end

--- Report what we are writing and where, for our typing notices: net and
--- target nil, or text empty, when we are writing nothing. Writing goes
--- on in one place at a time, so it ends on every other network.
---@param net string|nil
---@param target string|nil
---@param text string
function M.compose(net, target, text)
    for id in pairs(HUB.state.nets) do
        if id ~= net and enabled(id) then
            typing.compose(M, id, nil, '')
        end
    end
    if net and enabled(net) then
        typing.compose(M, net, target, text)
    end
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

--- WHOIS a nick, on its server (with idle time) if `remote`; the reply
--- opens in the detail pane.
---@param net string
---@param nick string
---@param remote boolean|nil
function M.whois(net, nick, remote)
    task.spawn('whois', {net = net, owner = M.name}, whois, nick, remote or false)
end

--- Ask again for a channel's modes and creation time.
function M.refresh_modes(net, name)
    query(net, 'MODE', name)
end

--- Fetch a list mode of a channel, such as its bans (b) or quiets (q).
function M.fetch_list(net, name, mode)
    query(net, 'MODE', name, '+' .. mode)
end

--- Remove an entry from a list mode of a channel.
function M.unset_list(net, name, mode, mask)
    query(net, 'MODE', name, '-' .. mode, mask)
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

local chat_command <const> = common.net_command(M.name)

-- The shown channel, for a command that acts on it. Whether we may is
-- the server's to say: halfops and opers with override can, unopped.
local function shown_channel(ctx)
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
local function ban_command(name, mode, help)
    return chat_command(name, '$g', 'nick', help, function(ctx, nick)
        local channel = shown_channel(ctx)
        task.spawn(name, {net = ctx.net, owner = M.name}, ban_nick, channel, nick, '+' .. mode)
    end)
end

-- Unset a list mode: a mask as given, or a nick's ban mask
local function unban_command(name, mode, help)
    local cmd = chat_command(name, '$g', 'mask|nick', help, function(ctx, arg)
        local channel = shown_channel(ctx)
        if is_mask(arg) then
            send.send(ctx.net, 'MODE', channel, '-' .. mode, arg)
        else
            task.spawn(name, {net = ctx.net, owner = M.name}, ban_nick, channel, arg, '-' .. mode)
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
            M.fetch_list(ctx.net, channel.name, mode)
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

-- Give (+o) or take (-o) a prefix mode for nicks in the shown channel, in
-- as few MODE lines as the server's MODES allows; with no nicks, bare()
local function prefix_command(name, change, help, bare)
    return chat_command(name, '$R', '[nick...]', help, function(ctx, args)
        local channel = shown_channel(ctx)
        local nicks = {}
        for nick in args:gmatch '%g+' do table.insert(nicks, nick) end
        if not nicks[1] then return bare(ctx.net, channel) end
        local irc = model(ctx.net)
        ---@cast irc -nil shown_channel needs it
        -- MODES with no value sets no limit
        local limit = irc.isupport.MODES
        local per = limit == true and #nicks or math.tointeger(tonumber(limit)) or 3
        per = math.max(per, 1)
        local sign, mode = change:sub(1, 1), change:sub(2)
        for i = 1, #nicks, per do
            local chunk = table.move(nicks, i, math.min(i + per - 1, #nicks), 1, {})
            send.send(ctx.net, 'MODE', channel, sign .. mode:rep(#chunk), table.unpack(chunk))
        end
    end)
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

local close_command = chat_command('close', '$R', '[target]',
    'Close a buffer, the shown one by default, parting its channel',
function(ctx, target)
    if target == '' then
        target = ctx.target
    end
    if not target then
        error('no buffer to close', 0)
    end
    M.close(ctx.net, target)
end)

-- Tab offers the network's open buffers
function close_command.complete(ctx, before, seed)
    if before ~= '' then return nil end
    local t = {}
    for _, buffer in pairs(M.get(ctx.net).buffers) do
        if buffer.name:sub(1, #seed) == seed then table.insert(t, buffer.name) end
    end
    return t
end

local topic_command = chat_command('topic', '$R', '[text]', "Set the shown channel's topic, or clear it",
function(ctx, text)
    send.send(ctx.net, 'TOPIC', shown_channel(ctx), text)
end)

-- Tab with nothing typed yet offers the current topic, to edit
function topic_command.complete(ctx, before, seed)
    if before ~= '' or seed ~= '' then return nil end
    local irc = model(ctx.net)
    local channel = irc and ctx.target and irc_model.get_channel(irc, ctx.target)
    if channel and channel.topic and channel.topic ~= '' then
        return {channel.topic}
    end
end

M.commands = {
    chat_command('talk', '$g', 'target', 'Talk to a channel or nick: opens a buffer, joins or monitors',
    function(ctx, target)
        M.talk(ctx.net, target)
        bus.emit('chat.focus', {net = ctx.net, target = target})
    end),
    close_command,
    chat_command('msg', '$g $r', 'target text', 'Send a message', function(ctx, target, text)
        M.say(ctx.net, target, text)
    end),
    chat_command('notice', '$g $r', 'target text', 'Send a notice', function(ctx, target, text)
        M.notice(ctx.net, target, text)
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
    topic_command,
    chat_command('list', '$R', '[pattern]', 'List channels, optionally matching a pattern', function(ctx, arg)
        M.list(ctx.net, arg)
        bus.emit('chat.show_list', {net = ctx.net})
    end),
    chat_command('whois', '$g', 'nick', 'WHOIS a nick, shown in the detail pane', function(ctx, nick)
        M.whois(ctx.net, nick)
    end),
    chat_command('wii', '$g', 'nick', 'WHOIS a nick on its server (with idle time)', function(ctx, nick)
        M.whois(ctx.net, nick, true)
    end),
    chat_command('whowas', '$g $R', 'nick [count]', 'WHOWAS a nick, at most count entries', function(ctx, nick, count)
        local n
        if count ~= '' then
            n = math.tointeger(tonumber(count))
            if not n or n < 1 then error('count must be a positive number: ' .. count, 0) end
        end
        task.spawn('whowas', {net = ctx.net, owner = M.name}, whowas, nick, n)
    end),
    ban_command('quiet', 'q', 'Quiet a nick in the shown channel'),
    ban_command('ban', 'b', 'Ban a nick from the shown channel'),
    chat_command('kickban', '$g $R', 'nick [reason]', 'Ban a nick from the shown channel and kick it',
    function(ctx, nick, reason)
        local channel = shown_channel(ctx)
        task.spawn('kickban', {net = ctx.net, owner = M.name}, ban_nick, channel, nick, '+b', reason)
    end),
    unban_command('unquiet', 'q', 'Unquiet a mask, or a nick by its ban mask, in the shown channel'),
    unban_command('unban', 'b', 'Unban a mask, or a nick by its ban mask, from the shown channel'),
    prefix_command('op', '+o', 'Op nicks in the shown channel, or ourselves through ChanServ',
        from_chanserv 'OP'),
    prefix_command('deop', '-o', 'Deop nicks in the shown channel, or ourselves', drop_own '-o'),
    prefix_command('voice', '+v', 'Voice nicks in the shown channel, or ourselves through ChanServ',
        from_chanserv 'VOICE'),
    prefix_command('devoice', '-v', 'Devoice nicks in the shown channel, or ourselves', drop_own '-v'),
    chat_command('umode', '$r', 'modes', 'Change our user modes, e.g. +i-w', function(ctx, args)
        local irc = model(ctx.net)
        if not irc then error('not connected', 0) end
        local parts = {}
        for word in args:gmatch '%S+' do table.insert(parts, word) end
        send.send(ctx.net, 'MODE', irc.nick, table.unpack(parts))
    end),
}

return M
