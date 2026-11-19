-- Chat: buffers of messages per network and target, mentions and
-- history. Its commands are in chat/commands.lua and chat/modes.lua.
--
-- state.features.chat[net] = {
--   buffers  [folded target] = {name, messages = OrderedMap, activity,
--            mention, typing}; activity counts unseen messages, messages
--            are keyed by their msgid tag when they have one, and typing
--            holds who is typing there (chat/typing.lua)
--   list     OrderedMap of /list results: {channel, users, topic}
--            (chat/channels.lua)
--   pending  [label] = {[folded target] = {msg, buffer}}: our labeled
--            PRIVMSG and NOTICE lines awaiting the server's reply
--            (chat/receipt.lua)
--   closing  [folded channel] = true: channels /close parted, whose buffer
--            goes when our PART comes back
--   composing what we are writing and where, for our typing notices
--            (chat/typing.lua)
--   monitoring [folded nick] = true: our MONITOR + awaiting its reply
--            (chat/monitor.lua)
-- }
--
-- Sending: replies to CTCP requests (paced, except to staff), CHATHISTORY
-- (chat/history.lua) and MONITOR (chat/monitor.lua) for buffers, our
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

local bus        <const> = require 'hub.runtime.bus'
local casemap    <const> = require 'hub.lib.casemap'
local channels   <const> = require 'hub.features.chat.channels'
local clock      <const> = require 'hub.runtime.clock'
local commands   <const> = require 'hub.features.chat.commands'
local common     <const> = require 'hub.features.common'
local config     <const> = require 'hub.features.chat.config'
local channel_errors <const> = require 'hub.lib.channel_errors'
local ctcp           <const> = require 'hub.features.chat.ctcp'
local hide       <const> = require 'hub.features.chat.hide'
local history    <const> = require 'hub.features.chat.history'
local intent     <const> = require 'hub.net.intent'
local irc_model  <const> = require 'hub.net.irc'
local log        <const> = require 'hub.runtime.log'
local message_text <const> = require 'hub.lib.message_text'
local monitor    <const> = require 'hub.features.chat.monitor'
local N          <const> = require 'hub.lib.numerics'
local OrderedMap <const> = require 'hub.lib.OrderedMap'
local ratelimit  <const> = require 'hub.lib.ratelimit'
local receipt    <const> = require 'hub.features.chat.receipt'
local send       <const> = require 'hub.net.send'
local task       <const> = require 'hub.runtime.task'
local typing     <const> = require 'hub.features.chat.typing'
local whois      <const> = require 'hub.features.chat.whois'

local M = {}

local query <const> = common.sender 'chat'

M.name = 'chat'
M.buffer_size = 1000
M.list_size = 10000
-- History requests new buffers may make at once, and the seconds that
-- earn another
M.history_burst = 10
M.history_interval = 6
-- CTCP replies to non-staff that may go at once, and the seconds that earn
-- another; the burst stays below a typical rate limit's (5 lines)
M.ctcp_burst = 2
M.ctcp_interval = 20

--- A buffer named for a server, which sends WALLOPS and messages to
--- broadcast masks; such a buffer has no history, typing or MONITOR. A
--- buffer from before, named *wallops, is one too.
---@param net string
---@param name string
---@return boolean
function M.is_server(net, name)
    if name:sub(1, 1) == '*' then return true end
    local rec = HUB.state.nets[net]
    local irc = rec and rec.irc
    local channel = irc and irc_model.is_channel_name(irc, name) or not irc and name:find '^[#&]'
    return not channel and name:find('.', 1, true) ~= nil
end

--- What chat's parts (chat/typing.lua, history.lua, receipt.lua,
--- channels.lua, monitor.lua, config.lua) use of chat, which they are
--- passed since it requires them.
---@class hub.ChatLookup
---@field is_server fun(net: string, name: string): boolean
---@field buffer_size integer
---@field get fun(net: string): hub.ChatState
---@field fold fun(net: string, target: string): string
---@field buffer fun(net: string, target: string): hub.ChatBuffer|nil
---@field open fun(net: string, target: string): hub.ChatBuffer
---@field insert fun(net: string, buffer: hub.ChatBuffer, msg: hub.Message)
---@field discards fun(net: string, target: string, msg: hub.Message): boolean
---@field newest fun(buffer: hub.ChatBuffer): hub.Message|nil

--- What chat's commands (chat/commands.lua, modes.lua) use of chat.
---@class hub.Chat : hub.ChatLookup
---@field name string
---@field name_matcher fun(net: string, seed: string): fun(name: string): boolean
---@field command fun(name: string, spec: string, usage: string, help: string, fn: function): table
---@field talk fun(net: string, target: string)
---@field say fun(net: string, target: string, text: string)
---@field notice fun(net: string, target: string, text: string)
---@field close fun(net: string, target: string)
---@field channel_info fun(net: string, name: string)
---@field list fun(net: string, arg: string)
---@field whois fun(net: string, nick: string, remote: boolean|nil)
---@field refresh_modes fun(net: string, name: string)
---@field refresh_topic fun(net: string, name: string)
---@field refetch_observed fun(net: string, name: string)
---@field fetch_list fun(net: string, name: string, mode: string)

--- A network's chat, state.features.chat[net].
---@class hub.ChatState
---@field buffers table<string, hub.ChatBuffer> by folded target
---@field list hub.OrderedMap the last LIST reply
---@field listing true|nil while LIST replies arrive
---@field list_count integer|nil channels the last LIST replied with, kept or not
---@field pending table<string, table<string, {msg: hub.Message, buffer: hub.ChatBuffer|nil}>>
--- by label, then by folded target; for the current connection
---@field closing table<string, true> channels /close parted, by folded name;
--- for the current connection
---@field composing hub.ChatComposing|nil what we are writing and where
---@field monitoring table<string, true>|nil nicks we sent MONITOR + for and
--- have had no reply about, by folded nick; for the current connection
--- (chat/monitor.lua)
---@field history_bucket number|nil pacing of new buffers' history requests (lib/ratelimit)
---@field ctcp_bucket number|nil pacing of CTCP replies to non-staff (lib/ratelimit)
---@field casemapping string|nil what the keys are folded with: the
--- network's, as last announced; rfc1459 before any

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

local function model(net)
    local rec = HUB.state.nets[net]
    return rec and rec.irc
end

--- Fold a target with the network's casemapping: the one the server
--- announced, or the one last announced while it hasn't (between
--- connections, and while registering), so keys stay the same.
function M.fold(net, target)
    local irc = model(net)
    if irc and irc.isupport.CASEMAPPING ~= nil then
        return irc_model.fold(irc, target)
    end
    local C = common.get_state(M.name, net)
    return casemap.fold(C and C.casemapping or 'rfc1459', target)
end

--- A test for names that start with seed, as the network folds them.
---@param net string
---@param seed string
---@return fun(name: string): boolean
function M.name_matcher(net, seed)
    local prefix = M.fold(net, seed)
    return function(name)
        return M.fold(net, name):sub(1, #prefix) == prefix
    end
end

-- Fold the keys again after the server announces its casemapping. Buffers
-- that come to fold alike merge into the one with more messages.
local function refold(net)
    local C = M.get(net)
    local irc = model(net)
    local casemapping = irc and irc.casemapping or 'rfc1459'
    if (C.casemapping or 'rfc1459') == casemapping then return end
    C.casemapping = casemapping
    local fold = function(s) return casemap.fold(casemapping, s) end

    local buffers = {}
    for _, buffer in pairs(C.buffers) do
        local key = fold(buffer.name)
        local other = buffers[key]
        if other then
            local keep, gone = other, buffer
            if OrderedMap.size(buffer.messages) > OrderedMap.size(other.messages) then
                keep, gone = buffer, other
            end
            keep.activity = keep.activity + gone.activity
            keep.mention = keep.mention or gone.mention
            buffers[key] = keep
            log.add_net(net, 'chat', '%s and %s are one buffer now; %s keeps its messages',
                keep.name, gone.name, keep.name)
        else
            buffers[key] = buffer
        end
        typing.refold(buffer, fold)
    end
    C.buffers = buffers
    -- pending and closing belong to the connection, and the server names
    -- its casemapping before anything goes into them
end

--- The configured settings of a buffer ([[networks.buffers]],
--- chat/config.lua), if any.
---@param net string
---@param target string
---@return hub.BufferSettings|nil
function M.settings(net, target)
    return config.settings(M, net, target)
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
---@field hide table<hub.Message, hub.HideDecision|false>|nil how each
--- message was classified (chat/hide.lua), weak-keyed; nil until one is

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
    -- what came before the message that opened it, or the latest; a flood
    -- of new senders gets a few such requests, not one each
    local now = clock.now()
    if not M.is_server(net, target)
    and ratelimit.wait(C.history_bucket or now, now, M.history_burst, M.history_interval) == 0 then
        C.history_bucket = ratelimit.take(C.history_bucket or now, now, M.history_interval)
        history.request(M, net, target, before and 'BEFORE' or 'LATEST', before)
    end
    bus.emit('chat.buffer', {net = net, target = target, opened = true})
    monitor.watch(M, net, target)
    return buffer
end

local function drop(net, key, target)
    M.get(net).buffers[key] = nil
    -- a channel's snapshot lasts as long as its buffer
    local irc = model(net)
    if irc then irc_model.forget_observed(irc, target) end
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
    if irc then
        monitor.unwatch(net, irc, target)
    end
    -- not rejoined on the next connection, even when we couldn't part
    intent.left(HUB.state.nets[net], irc, target)
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
-- itself. Others are reached only by iteration. The hide rules classify
-- it first (chat/hide.lua), since the map asks the view's predicate
-- whether it is shown as it goes in.
local function insert(net, buffer, msg)
    hide.classify(M, net, buffer, msg)
    local key = msgid(msg)
    if key == nil and msg.receipt == 'awaiting' then key = msg end
    OrderedMap.insert(buffer.messages, key, msg)
end
M.insert = insert -- for chat/history.lua and receipt.lua

--- Whether the hide rules hide a message in a buffer (chat/hide.lua).
M.hidden = hide.hidden

--- Whether the hide rules discard a message bound for a buffer, which
--- is then neither opened nor added to (chat/hide.lua).
---@param net string
---@param target string
---@param msg hub.Message
---@return boolean
function M.discards(net, target, msg)
    return hide.discards(M, net, target, msg)
end

--- How the hide rules classified a message in a buffer, or nil when
--- none decided (chat/hide.lua).
M.hide_decision = hide.decision

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

-- Whether a buffer holds a message: by its msgid when it has one, else
-- by searching
local function holds(buffer, msg)
    local id = msgid(msg)
    if id and M.find(buffer, id) == msg then return true end
    return OrderedMap.find(buffer.messages, function(other) return other == msg end) ~= nil
end

--- A buffer of a network that holds a message: the one named `prefer`
--- when it does, else the first by name. Nil when none does.
---@param net string
---@param msg hub.Message
---@param prefer string|nil
---@return hub.ChatBuffer|nil
function M.holder(net, msg, prefer)
    if not enabled(net) then return nil end
    local preferred = prefer and M.buffer(net, prefer)
    if preferred and holds(preferred, msg) then return preferred end
    local best, best_key
    for key, buffer in pairs(M.get(net).buffers) do
        if buffer ~= preferred and (not best_key or key < best_key) and holds(buffer, msg) then
            best, best_key = buffer, key
        end
    end
    return best
end

--- Whom of some nicks spoke last in a buffer, not counting us.
---@generic T
---@param net string
---@param target string
---@param nicks table<string, T> by folded nick
---@return T|nil # the value of the nick found
function M.last_speaker(net, target, nicks)
    local buffer = enabled(net) and M.buffer(net, target)
    if not buffer then return nil end
    local irc = model(net)
    for msg in OrderedMap.each(buffer.messages) do
        if msg.nick and (msg.command == 'PRIVMSG' or msg.command == 'NOTICE') then
            local found = nicks[M.fold(net, msg.nick)]
            if found and not (irc and irc_model.is_me(irc, msg.nick)) then return found end
        end
    end
    return nil
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

-- Place a message in a buffer, opening it if need be, unless the hide
-- rules discard it; false when they do
local function add(net, target, msg, mention, activity)
    if hide.discards(M, net, target, msg) then return false end
    local buffer = M.open(net, target, msg.tags and msg.tags.time)
    local id = msgid(msg)
    -- a message the buffer already has, from history or a bouncer
    if id and M.find(buffer, id) then return true end
    insert(net, buffer, msg)
    -- a hidden message never counts; a buffer configured with activity =
    -- false is unseen only by mentions
    local hidden = hide.hidden(buffer, msg)
    if hidden then
        mention, activity = false, false
    elseif activity and not mention then
        local settings = M.settings(net, target)
        if settings and settings.activity == false then activity = false end
    end
    if mention then
        buffer.mention = true
    end
    if activity then
        buffer.activity = buffer.activity + 1
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
        return add(net, target, msg, config.matches(config.mention(M, net, target), plain), true)
    end

    -- to us, to a broadcast mask ($$*.net), or to a nick we just left: in
    -- the sender's buffer, or the channel it is meant for; only one to us
    -- is a mention, unless that buffer has its own patterns or regexes,
    -- and never a CTCP request (VERSION, PING) other than an action
    local sender = nick or msg.source
    if sender then
        local buffer = context and nick and context or sender
        local ctcp_request = text:find '^\x01' and not text:find '^\x01ACTION'
        local own = config.own_mention(M, net, buffer)
        local mention = false
        if not ctcp_request then
            if own then
                mention = config.matches(own, plain)
            else
                mention = irc_model.is_me(irc, target)
            end
        end
        if buffer == context then msg.context = '>' end
        return add(net, buffer, msg, mention, true)
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
        local C = M.get(net)
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
    -- server notices belong to the snotice feature, which marks them
    -- before chat hears the message (app.lua)
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
            if not hide.discards(M, net, buffer.name, msg) then insert(net, buffer, msg) end
            return
        end
        buffer.name = msg[1]
        if new ~= old then
            C.buffers[old] = nil
            C.buffers[new] = buffer
            -- the buffer watches its nick by its new name
            local irc = model(net)
            if irc then
                monitor.unwatch(net, irc, msg.nick)
                monitor.watch(M, net, msg[1])
            end
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
--- channel (lib/channel_errors.lua).
M.channel_errors = channel_errors

local function channel_error(net, irc, msg)
    local channel = msg[M.channel_errors[msg.command]]
    if channel and irc_model.is_channel_name(irc, channel) and M.buffer(net, channel) then
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
    receipt.on_refusal(M, net, irc, msg)
end

-- Replies to our MONITOR + (chat/monitor.lua), after the model's
for _, n in ipairs {N.RPL_MONONLINE, N.RPL_MONOFFLINE, N.ERR_MONLISTFULL} do
    H[n] = function(net, irc, msg) monitor.on_reply(M, net, irc, msg) end
end

-- Replies to LIST (chat/channels.lua)
for command, h in pairs(channels.handlers) do
    H[command] = function(net, _, msg) h(M, net, msg) end
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
    history.after_registration(M, net)
    monitor.after_registration(M, net, irc)
end

M.routes = {
    -- a private buffer watches this nick (chat/monitor.lua), so MONITOR
    -- must keep it
    ['chat.monitors'] = function(net, nick)
        local C = common.get_state(M.name, net)
        return C ~= nil and C.buffers[M.fold(net, nick)] ~= nil
    end,
}

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
        monitor.reset(C)
        C.closing = {}
    end)
    sub.on('net.removed', function(ev) common.drop_state(M.name, ev.net) end)
    sub.on('irc.isupport', function(ev)
        if ev.key == 'CASEMAPPING' and enabled(ev.net) then refold(ev.net) end
    end)
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
        if id ~= net and enabled(id) then
            typing.compose(M, id, nil, '')
        end
    end
    if net and enabled(net) then
        typing.compose(M, net, target, text)
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

-- Channels (chat/channels.lua) ========================================

--- Ask for what a channel's information needs: for a joined channel its
--- modes when unknown, for another a snapshot and all that it holds.
function M.channel_info(net, name) channels.channel_info(M, net, name) end

--- After a change we made in a channel we aren't in, ask again for its
--- snapshot.
M.refetch_observed = channels.refetch_observed

--- Ask again for a channel's modes and creation time.
function M.refresh_modes(net, name) channels.refresh_modes(M, net, name) end

--- Ask again for a channel's topic.
function M.refresh_topic(net, name) channels.refresh_topic(M, net, name) end

--- Fetch a list mode of a channel, such as its bans (b) or quiets (q).
function M.fetch_list(net, name, mode) channels.fetch_list(M, net, name, mode) end

--- Remove an entry from a list mode of a channel.
M.unset_list = channels.unset_list

--- Fetch the channel list.
function M.list(net, arg) channels.list(M, net, arg) end

-- Commands ============================================================

M.command = common.net_command(M.name)
M.commands = commands.commands(M)

return M
