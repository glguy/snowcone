-- Chat: buffers of messages per network and target, mentions and
-- history. This module routes messages to buffers, and is what the rest
-- of hub uses; its commands, in chat/commands.lua and chat/modes.lua,
-- build on it. Its parts, each requiring only those before it:
--
--   store.lua                           state, folding, finding buffers
--   config.lua, hide.lua, typing.lua    settings, hide rules, typing
--   buffers.lua                         what a buffer holds
--   history.lua, receipt.lua            chat history, our own lines
--   opening.lua                         opening and closing buffers
--   channels.lua                        asking about channels
--
-- state.features.chat[net] = {
--   buffers  [folded target] = {name, messages = OrderedMap, activity,
--            mention, typing}; activity counts unseen messages, messages
--            are keyed by their msgid tag when they have one, and typing
--            holds who is typing there (chat/typing.lua)
--   pending  [label] = {[folded target] = {msg, buffer}}: our labeled
--            PRIVMSG and NOTICE lines awaiting the server's reply
--            (chat/receipt.lua)
--   closing  [folded channel] = true: channels /close parted, whose buffer
--            goes when our PART comes back
--   composing what we are writing and where, for our typing notices
--            (chat/typing.lua)
-- }
--
-- Sending: replies to CTCP requests (paced, except to staff), CHATHISTORY
-- (chat/history.lua) for buffers, MONITOR for private ones (through
-- net/monitor.lua), our
-- typing (TAGMSG, chat/typing.lua), and what the commands ask for, such
-- as a channel's modes and topic (chat/channels.lua). PRIVMSG and NOTICE
-- go out only from commands and talk mode. Bans, quiets and kicks go out
-- at once, without staging: they reach one channel and are easily
-- undone.
--
-- Our own PRIVMSG and NOTICE lines are shown from irc.sent, and with
-- labeled-response await the server's reply (chat/receipt.lua).
--
-- A buffer's configured settings ([[networks.buffers]], chat/config.lua)
-- may give it its own mention patterns or regexes, which in a private
-- buffer replace the rule that every message to us is a mention, and
-- with activity = false leave its messages other than mentions seen.
--
-- A private message with the channel-context tag naming a channel we are
-- in is shown in that channel's buffer, marked msg.context: '>' from the
-- sender to us, '<' from us to the recipient. /cmsg sends one.

local buffers        <const> = require 'hub.features.chat.buffers'
local bus            <const> = require 'hub.runtime.bus'
local casemap        <const> = require 'hub.lib.casemap'
local channel_errors <const> = require 'hub.features.chat.channel_errors'
local channels       <const> = require 'hub.features.chat.channels'
local clock          <const> = require 'hub.runtime.clock'
local common         <const> = require 'hub.features.common'
local config         <const> = require 'hub.features.chat.config'
local ctcp           <const> = require 'hub.features.chat.ctcp'
local hide           <const> = require 'hub.features.chat.hide'
local history        <const> = require 'hub.features.chat.history'
local irc_model      <const> = require 'hub.net.irc'
local log            <const> = require 'hub.runtime.log'
local message_text   <const> = require 'hub.lib.message_text'
local monitor        <const> = require 'hub.net.monitor'
local N              <const> = require 'hub.lib.numerics'
local opening        <const> = require 'hub.features.chat.opening'
local OrderedMap     <const> = require 'hub.lib.OrderedMap'
local ratelimit      <const> = require 'hub.lib.ratelimit'
local receipt        <const> = require 'hub.features.chat.receipt'
local send           <const> = require 'hub.net.send'
local store          <const> = require 'hub.features.chat.store'
local typing         <const> = require 'hub.features.chat.typing'

local M = {}

local query <const> = common.sender 'chat'

-- What the UI, notify and chat's commands use of its parts

M.name = store.name
M.get = store.get
M.fold = store.fold
M.name_matcher = store.name_matcher
M.buffer = store.buffer
M.settings = config.settings

M.open = opening.open
M.close = opening.close

M.look = buffers.look
M.find = buffers.find
M.newest = buffers.newest
M.holder = buffers.holder
M.next_buffer = buffers.next_buffer
M.last_speaker = buffers.last_speaker

M.hidden = hide.hidden
M.hide_decision = hide.decision

M.typing = typing.list

M.channel_info = channels.channel_info
M.refetch_observed = channels.refetch_observed
M.refresh_modes = channels.refresh_modes
M.refresh_topic = channels.refresh_topic
M.fetch_list = channels.fetch_list
M.unset_list = channels.unset_list

-- CTCP replies to non-staff that may go at once, and the seconds that earn
-- another; the burst stays below a typical rate limit's (5 lines)
M.ctcp_burst = 2
M.ctcp_interval = 20

-- Fold the keys again after the server announces its casemapping. Buffers
-- that come to fold alike merge into the one with more messages.
local function refold(net)
    local C = store.get(net)
    local irc = store.model(net)
    local casemapping = irc and irc.casemapping or 'rfc1459'
    if (C.casemapping or 'rfc1459') == casemapping then return end
    C.casemapping = casemapping
    local fold = function(s) return casemap.fold(casemapping, s) end

    local merged = {}
    for _, buffer in pairs(C.buffers) do
        local key = fold(buffer.name)
        local other = merged[key]
        if other then
            local keep, gone = other, buffer
            if OrderedMap.size(buffer.messages) > OrderedMap.size(other.messages) then
                keep, gone = buffer, other
            end
            keep.activity = keep.activity + gone.activity
            keep.mention = keep.mention or gone.mention
            merged[key] = keep
            log.add_net(net, 'chat', '%s and %s are one buffer now; %s keeps its messages',
                keep.name, gone.name, keep.name)
        else
            merged[key] = buffer
        end
        typing.refold(buffer, fold)
    end
    C.buffers = merged
    -- pending and closing belong to the connection, and the server names
    -- its casemapping before anything goes into them
end

-- Place a message in a buffer, opening it if need be, unless the hide
-- rules discard it; false when they do. `matched`: its text matched
-- mention settings, which marks the message itself; a private message
-- can be a mention without that, by being to us.
local function add(net, target, msg, mention, activity, matched)
    if hide.discards(net, target, msg) then return false end
    local buffer = opening.open(net, target, msg.tags and msg.tags.time)
    local id = buffers.msgid(msg)
    -- a message the buffer already has, from history or a bouncer
    if id and buffers.find(buffer, id) then return true end
    buffers.insert(net, buffer, msg)
    -- a hidden message never counts; a buffer configured with activity =
    -- false is unseen only by mentions
    local hidden = hide.hidden(buffer, msg)
    if hidden then
        mention, activity = false, false
    elseif activity and not mention then
        local settings = config.settings(net, target)
        if settings and settings.activity == false then activity = false end
    end
    if mention then
        buffer.mention = true
    end
    if matched and not hidden then
        msg.mention = true
    end
    if activity then
        buffer.activity = buffer.activity + 1
    end
    if (mention or activity) and not buffer.first_unseen then
        buffer.first_unseen = msg
    end
    bus.emit('chat.message', {net = net, target = target, msg = msg, mention = mention,
        activity = activity, hidden = hidden})
    return true
end

-- Routing =============================================================

-- Where a message belongs: channel messages in the channel, private ones
-- in a buffer named for the other side, unless they are meant to be
-- shown in a channel we are in (channel-context). False when the hide
-- rules discard it.
local function route_chat(net, irc, target, text, msg)
    local nick = msg.nick
    -- mentions are matched on the text without formatting, as hide rules
    -- and filters are (lib/message_text.lua)
    local plain = message_text.plain(text)
    local context = not msg.statusmsg and irc_model.channel_context(irc, target, msg.tags)
    -- ours, relayed by a bouncer from another client, echoed or replayed:
    -- never a mention, never unseen
    if nick and irc_model.is_me(irc, nick) then
        if context then
            msg.context = '<'
            return add(net, context, msg, false, false)
        end
        return add(net, target, msg, false, false)
    end

    if irc_model.is_channel_name(irc, target) then
        local matched = config.matches(config.mention(net, target), plain)
        return add(net, target, msg, matched, true, matched)
    end

    -- to us, to a broadcast mask ($$*.net), or to a nick we just left: in
    -- the sender's buffer, or the channel it is meant for; only one to us
    -- is a mention, unless that buffer has its own patterns or regexes,
    -- and never a CTCP request (VERSION, PING) other than an action. The
    -- message itself is marked only when its text matches mention
    -- settings, else every message there would be.
    local sender = nick or msg.source
    if sender then
        local buffer = context and nick and context or sender
        local ctcp_request = text:find '^\x01' and not text:find '^\x01ACTION'
        local own = config.own_mention(net, buffer)
        local mention, matched = false, false
        if not ctcp_request then
            matched = config.matches(config.mention(net, buffer), plain)
            if own then
                mention = matched
            else
                mention = irc_model.is_me(irc, target)
            end
        end
        if buffer == context then msg.context = '>' end
        return add(net, buffer, msg, mention, true, matched)
    end
    return true
end

-- Add a membership change to the buffers of the channels it concerns
local function to_channels(net, names, msg)
    for _, name in ipairs(names) do
        add(net, name, msg, false, false)
    end
end

local function to_user(net, nick, msg)
    if nick and store.buffer(net, nick) then
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

-- Anyone can send us requests, and each reply spends the network's rate
-- limit, so only staff are always answered. Others share a small budget,
-- and get no reply while a reply would have to wait: requests can't build
-- a backlog in front of what the user sends. The budget is the network's,
-- not the sender's, since a flood can come from many nicks.
local function answer_ctcp(net, nick, staff, name, args)
    local h = ctcp[name]
    local response = h and h(args)
    if not response then return end
    if not staff then
        local C = store.get(net)
        local now = clock.now()
        local bucket = C.ctcp_bucket or now
        if ratelimit.wait(bucket, now, M.ctcp_burst, M.ctcp_interval) > 0
        or not send.ready(net) then
            return
        end
        C.ctcp_bucket = ratelimit.take(bucket, now, M.ctcp_interval)
    end
    query(net, 'NOTICE', nick, '\x01' .. name .. ' ' .. response .. '\x01')
end

function H.PRIVMSG(net, irc, msg)
    local prefix, target = irc_model.split_statusmsg(irc, msg[1])
    local text = msg[2]
    msg.statusmsg = prefix

    -- the request first, so it opens the sender's buffer that our reply
    -- is then shown in
    local kept = route_chat(net, irc, target, text, msg)

    -- answer only CTCP requests sent to us, not to a channel, and none
    -- the hide rules discard
    local name, args = text:match '^\x01([^\x01 ]+) ?([^\x01]*)\x01?$'
    if name and kept and msg.nick and irc_model.is_me(irc, target) then
        answer_ctcp(net, msg.nick, msg.tags['solanum.chat/oper'] ~= nil, name:upper(), args)
    end
end

function H.NOTICE(net, irc, msg)
    -- server notices belong to the snotice feature (net/snote marks them)
    if msg[1] == '*' or msg.snote then return end
    local prefix, target = irc_model.split_statusmsg(irc, msg[1])
    msg.statusmsg = prefix
    route_chat(net, irc, target, msg[2], msg)
end

function H.WALLOPS(net, _, msg)
    local sender = msg.nick or msg.source
    if sender then
        add(net, sender, msg, false, true)
    end
end
H.OPERWALL = H.WALLOPS

function H.JOIN(net, irc, msg)
    if irc_model.is_me(irc, msg.nick) then
        store.get(net).closing[store.fold(net, msg[1])] = nil
    end
    add(net, msg[1], msg, false, false)
end

function H.PART(net, irc, msg)
    local C = store.get(net)
    local key = store.fold(net, msg[1])
    if irc_model.is_me(irc, msg.nick) and C.closing[key] then
        C.closing[key] = nil
        local buffer = C.buffers[key]
        if buffer then opening.drop(net, key, buffer.name) end
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
    local C = store.get(net)
    local old = msg.nick and store.fold(net, msg.nick)
    local buffer = old and C.buffers[old]
    if buffer then
        local new = store.fold(net, msg[1])
        if new ~= old and C.buffers[new] then
            -- a buffer for the new nick exists: keep both, unrenamed
            if not hide.discards(net, buffer.name, msg) then buffers.insert(net, buffer, msg) end
            return
        end
        buffer.name = msg[1]
        if new ~= old then
            C.buffers[old] = nil
            C.buffers[new] = buffer
            -- the buffer watches its nick by its new name
            monitor.release(net, 'chat', msg.nick)
            opening.watch(net, msg[1])
        end
        add(net, msg[1], msg, false, false)
        -- what names the buffer elsewhere (the UI's shown buffer, notify)
        -- follows it
        bus.emit('chat.rename', {net = net, from = msg.nick, to = msg[1]})
    end
end

local function user_change(net, irc, msg)
    if not msg.nick then return end
    to_channels(net, channels_with(irc, msg.nick), msg)
    to_user(net, msg.nick, msg)
end
H.ACCOUNT = user_change
H.CHGHOST = user_change

--- Errors about a channel, by numeric: which parameter names the
--- channel (chat/channel_errors.lua).
M.channel_errors = channel_errors

local function channel_error(net, irc, msg)
    local channel = msg[M.channel_errors[msg.command]]
    if channel and irc_model.is_channel_name(irc, channel) and store.buffer(net, channel) then
        add(net, channel, msg, false, false)
    end
end
for n in pairs(M.channel_errors) do
    H[n] = channel_error
end

-- "<client> <channel> <forward> :<reason>": the server joins us to
-- <forward> instead. Both buffers show it, and the UI follows to <forward>.
H[N.ERR_LINKCHANNEL] = function(net, irc, msg)
    local from, to = msg[2], msg[3]
    if not (from and to) then return end
    channel_error(net, irc, msg)
    add(net, to, msg, false, false)
    bus.emit('chat.forward', {net = net, from = from, to = to})
end

-- "<client> <channel> :<reason>": our line there was refused
H[N.ERR_CANNOTSENDTOCHAN] = function(net, irc, msg)
    receipt.on_refusal(net, irc, msg)
end

local function on_message(ev)
    if not store.enabled(ev.net) then return end
    local irc = store.model(ev.net)
    if not irc then return end
    if receipt.on_reply(ev.net, irc, ev.msg) then return end
    -- first, while the buffers are as they were before the message
    typing.handle(ev.net, irc, ev.msg)
    local h = H[ev.msg.command]
    if h then
        h(ev.net, irc, ev.msg)
    end
end

-- Our own messages, shown where they went; a labeled one awaits its reply
local function on_sent(ev)
    if not store.enabled(ev.net) then return end
    local msg = ev.msg
    if msg.command ~= 'PRIVMSG' and msg.command ~= 'NOTICE' then return end
    local irc = store.model(ev.net)
    if not irc then return end
    typing.on_sent(ev.net, msg)
    receipt.on_sent(ev.net, irc, msg)
end

-- Chat history arrives in batches, and so does a reply to a line with
-- several targets
local function on_batch(ev)
    if not store.enabled(ev.net) then return end
    receipt.on_batch_end(ev.net, ev.label)
    if ev.type ~= 'chathistory' then return end
    history.on_batch(ev)
end

-- After registration: history for the open buffers, and MONITOR for the
-- private ones
local function on_registered(ev)
    local net = ev.net
    if not store.enabled(net) then return end
    history.after_registration(net)
    opening.watch_all(net)
end

--- Check chat's part of a configuration: mentions, buffers and hide
--- rules, whose matching fields become lists.
---@param cfg table
function M.check_config(cfg)
    config.check(cfg)
    for _, net in ipairs(cfg.networks) do hide.check(net) end
end

function M.subscribe(sub)
    sub.on('irc.message', on_message)
    sub.on('irc.sent', on_sent)
    sub.on('irc.batch', on_batch)
    sub.on('net.registered', on_registered)
    -- labels start again on the next connection
    sub.on('net.closed', function(ev)
        if not store.enabled(ev.net) then return end
        local C = store.get(ev.net)
        receipt.settle_all(C)
        typing.reset(C)
        C.closing = {}
    end)
    sub.on('net.removed', function(ev) common.drop_state(store.name, ev.net) end)
    sub.on('irc.isupport', function(ev)
        if ev.key == 'CASEMAPPING' and store.enabled(ev.net) then refold(ev.net) end
    end)
end

-- Talking =============================================================

--- Open a buffer to talk in: join a channel we aren't in, monitor a nick.
function M.talk(net, target)
    local irc = store.model(net)
    opening.open(net, target)
    if irc and HUB.state.nets[net].phase == 'connected' then
        if irc_model.is_channel_name(irc, target) then
            if not irc_model.get_channel(irc, target) then
                query(net, 'JOIN', target)
            end
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

--- Bytes an action adds to its text.
M.action_overhead = #'\x01ACTION \x01'

--- Report what we are writing and where, for our typing notices: net and
--- target nil, or text empty, when we are writing nothing. Writing goes
--- on in one place at a time, so it ends on every other network.
---@param net string|nil
---@param target string|nil
---@param text string
function M.compose(net, target, text)
    for id in pairs(HUB.state.nets) do
        if id ~= net and store.enabled(id) then
            typing.compose(id, nil, '')
        end
    end
    if net and store.enabled(net) then
        typing.compose(net, target, text)
    end
end

return M
