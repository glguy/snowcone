-- Chat: buffers of messages per network and target, mentions and
-- history. Its commands are in chat/commands.lua and chat/modes.lua.
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

local bus        <const> = require 'hub.runtime.bus'
local casemap    <const> = require 'hub.lib.casemap'
local commands   <const> = require 'hub.features.chat.commands'
local common     <const> = require 'hub.features.common'
local ctcp       <const> = require 'hub.features.chat.ctcp'
local history    <const> = require 'hub.features.chat.history'
local irc_model  <const> = require 'hub.net.irc'
local log        <const> = require 'hub.runtime.log'
local N          <const> = require 'hub.lib.numerics'
local OrderedMap <const> = require 'hub.lib.OrderedMap'
local receipt    <const> = require 'hub.features.chat.receipt'
local send       <const> = require 'hub.net.send'
local task       <const> = require 'hub.runtime.task'
local typing     <const> = require 'hub.features.chat.typing'
local whois      <const> = require 'hub.features.chat.whois'

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

--- What chat's commands (chat/commands.lua, modes.lua) use of chat.
---@class hub.Chat : hub.ChatLookup
---@field name string
---@field command fun(name: string, spec: string, usage: string, help: string, fn: function): table
---@field talk fun(net: string, target: string)
---@field say fun(net: string, target: string, text: string)
---@field notice fun(net: string, target: string, text: string)
---@field close fun(net: string, target: string)
---@field channel_info fun(net: string, name: string)
---@field list fun(net: string, arg: string)
---@field whois fun(net: string, nick: string, remote: boolean|nil)
---@field refresh_modes fun(net: string, name: string)
---@field fetch_list fun(net: string, name: string, mode: string)

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
        if buffer.typing then
            local typing_ = {}
            for _, entry in pairs(buffer.typing) do typing_[fold(entry.nick)] = entry end
            buffer.typing = typing_
        end
    end
    C.buffers = buffers
    -- pending and closing belong to the connection, and the server names
    -- its casemapping before anything goes into them
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

--- Errors about a channel, by numeric: which parameter names the
--- channel. A JOIN refused, or a change we asked for there, is shown in
--- the channel's buffer, which would otherwise show nothing happened.
M.channel_errors = {
    [N.ERR_NOSUCHCHANNEL] = 2,      -- <channel> :reason
    [N.ERR_TOOMANYCHANNELS] = 2,
    [N.ERR_BANNICKCHANGE] = 3,      -- <nick> <channel> :reason
    [N.ERR_UNAVAILRESOURCE] = 2,    -- a channel juped, or a nick
    [N.ERR_USERNOTINCHANNEL] = 3,   -- <nick> <channel> :reason
    [N.ERR_NOTONCHANNEL] = 2,
    [N.ERR_LINKCHANNEL] = 2,        -- <channel> <forward> :reason
    [N.ERR_CHANNELISFULL] = 2,
    [N.ERR_INVITEONLYCHAN] = 2,
    [N.ERR_BANNEDFROMCHAN] = 2,
    [N.ERR_BADCHANNELKEY] = 2,
    [N.ERR_BADCHANMASK] = 2,
    [N.ERR_NEEDREGGEDNICK] = 2,
    [N.ERR_BANLISTFULL] = 2,        -- <channel> <mode> :reason
    [N.ERR_BADCHANNAME] = 2,
    [N.ERR_THROTTLE] = 2,
    [N.ERR_CHANOPRIVSNEEDED] = 2,
    [N.ERR_VOICENEEDED] = 2,
    [N.ERR_KEYSET] = 2,
    [N.ERR_MLOCKRESTRICTED] = 2,    -- <channel> <mode> <mlock> :reason
}

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

M.command = common.net_command(M.name)
M.commands = commands.commands(M)

return M
