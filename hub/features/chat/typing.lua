-- Who is typing in chat's buffers: +typing on a TAGMSG (the IRCv3 typing
-- spec) to a channel or to us, kept only in a buffer that already exists:
-- a nick typing to us doesn't open one. An entry lasts until its timeout,
-- or until the nick sends a message there, leaves, or says done; a nick
-- change carries it over.
--
-- Ours goes out as the UI reports what we are writing and where
-- (M.compose): active at once and every few seconds while the line
-- changes, paused after a while without a change, and done when the line
-- is emptied or abandoned. A message sent there ends it without done, as
-- it does for those who receive it. Notices go out only where the network
-- takes the tag (message-tags, CLIENTTAGDENY), to a buffer we can reach,
-- and only when they would be written at once: one held back by the rate
-- limit would be stale when it went, and would delay real lines. A buffer
-- whose notice the server refuses (a moderated channel, a nick gone) gets
-- no more of them until we write another line there.
--
-- Entries live in buffer.typing (hub.ChatBuffer), and what we are writing
-- in C.composing (hub.ChatState). Chat requires this
-- module, so it passes itself in for folding and finding buffers, and
-- calls handle on each message before its own handlers: a nick change
-- is followed here before chat renames the private buffer.

local clock     <const> = require 'hub.runtime.clock'
local irc_model <const> = require 'hub.net.irc'
local log       <const> = require 'hub.runtime.log'
local N         <const> = require 'hub.lib.numerics'
local send      <const> = require 'hub.net.send'

local M = {}

--- Seconds an entry lasts without being refreshed, by state.
M.timeout = {active = 6, paused = 30}

---@class hub.ChatTyping
---@field nick string as last seen
---@field state 'active'|'paused'
---@field changed number clock.now() when it started or changed state;
--- a refresh in the same state keeps it
---@field expires number clock.now() when it lapses

--- Forget a nick's typing in a buffer.
local function stop_typing(chat, net, buffer, nick)
    if buffer and buffer.typing and nick then
        buffer.typing[chat.fold(net, nick)] = nil
    end
end

--- Who is typing in a buffer, the most recent change first (ties by
--- folded nick); expired entries are dropped.
---@param chat hub.ChatLookup
---@param net string
---@param buffer hub.ChatBuffer
---@return hub.ChatTyping[]
function M.list(chat, net, buffer)
    local list = {}
    if not buffer.typing then return list end
    local now = clock.now()
    for key, entry in pairs(buffer.typing) do
        if now >= entry.expires then
            buffer.typing[key] = nil
        else
            table.insert(list, entry)
        end
    end
    table.sort(list, function(a, b)
        if a.changed ~= b.changed then return a.changed > b.changed end
        return chat.fold(net, a.nick) < chat.fold(net, b.nick)
    end)
    return list
end

--- Nobody's typing outlives the connection, ours included.
---@param C hub.ChatState
function M.reset(C)
    for _, buffer in pairs(C.buffers) do buffer.typing = nil end
    C.composing = nil
end

-- Ours ================================================================

--- Seconds between our active notices while the line keeps changing.
M.refresh = 4

--- Seconds without a change to the line before we say we paused.
M.pause = 10

---@class hub.ChatComposing
---@field target string the buffer's name
---@field text string the line as last reported
---@field state 'active'|'paused'|nil what the buffer last heard from us
---@field sent number clock.now() of the last active notice
---@field edited number clock.now() of the last change to the line
---@field refused true|nil the server refused a notice there

-- Tell a buffer how our typing goes; false when the notice couldn't go
-- out at once
local function tell(chat, net, target, state)
    local rec = HUB.state.nets[net]
    local irc = rec and rec.irc
    if not (irc and rec.phase == 'connected' and send.ready(net)) then return false end
    if not irc_model.client_tag_allowed(irc, 'typing') then return false end
    if chat.fold(net, target) == chat.fold(net, chat.wallops) or not chat.buffer(net, target) then
        return false
    end
    if irc_model.is_channel_name(irc, target) then
        if not irc_model.get_channel(irc, target) then return false end
    else
        -- a monitored nick known to be offline would only answer with an
        -- error
        local monitor = irc_model.get_monitor(irc, target)
        if monitor and not monitor.user then return false end
    end
    local ok, err = pcall(send.send_tagged, net, {['+typing'] = state}, 'TAGMSG', target)
    if not ok then
        log.add_net(net, 'chat', '%s', err)
    end
    return ok
end

--- What we are writing in a network's buffer, reported after each input
--- event and each second; a nil target, or an empty line, when we are
--- writing nothing there.
---@param chat hub.ChatLookup
---@param net string
---@param target string|nil
---@param text string
function M.compose(chat, net, target, text)
    local C = chat.get(net)
    local entry = C.composing
    if entry and not (target and text ~= '' and chat.fold(net, entry.target) == chat.fold(net, target)) then
        if entry.state then tell(chat, net, entry.target, 'done') end
        C.composing, entry = nil, nil
    end
    if not target or text == '' then return end

    local now = clock.now()
    if not entry then
        entry = {target = target, text = '', sent = now, edited = now}
        C.composing = entry
    end
    if text ~= entry.text then
        entry.text = text
        entry.edited = now
    end
    if entry.refused then return end
    if now - entry.edited >= M.pause then
        if entry.state == 'active' and tell(chat, net, target, 'paused') then
            entry.state = 'paused'
        end
    elseif entry.state ~= 'active' or now - entry.sent >= M.refresh then
        if tell(chat, net, target, 'active') then
            entry.state = 'active'
            entry.sent = now
        end
    end
end

--- Our message to the buffer we are writing in ends our typing there.
---@param chat hub.ChatLookup
---@param net string
---@param msg hub.Message our PRIVMSG or NOTICE
function M.on_sent(chat, net, msg)
    local C = chat.get(net)
    local entry = C.composing
    if entry and msg[1] and chat.fold(net, msg[1]) == chat.fold(net, entry.target) then
        C.composing = nil
    end
end

local H = {}

-- An error naming the buffer we are writing in: the buffer heard nothing,
-- so it needs no done either
local function refused(chat, net, target)
    local entry = chat.get(net).composing
    if entry and target and chat.fold(net, target) == chat.fold(net, entry.target) then
        entry.refused = true
        entry.state = nil
    end
end

local function refusal(chat, net, _, msg)
    refused(chat, net, msg[2])
end

H[N.ERR_NOSUCHNICK] = refusal
H[N.ERR_NOSUCHCHANNEL] = refusal
H[N.ERR_CANNOTSENDTOCHAN] = refusal
H[N.ERR_CANNOTSENDTOUSER] = refusal

-- A standard reply names no target in a fixed place, so FAIL TAGMSG
-- counts against the buffer we are writing in
function H.FAIL(chat, net, _, msg)
    local entry = msg[1] == 'TAGMSG' and chat.get(net).composing
    if entry then refused(chat, net, entry.target) end
end

-- A message ends the nick's typing in the buffer chat puts it in: the
-- channel, the target of one of ours, or the sender of one to us
function H.PRIVMSG(chat, net, irc, msg)
    local nick = msg.nick
    if not (nick and msg[1]) then return end
    local _, target = irc_model.split_statusmsg(irc, msg[1])
    local name
    if irc_model.is_channel_name(irc, target) or irc_model.is_me(irc, nick) then
        name = target
    elseif irc_model.is_me(irc, target) then
        name = nick
    end
    if name then
        stop_typing(chat, net, chat.buffer(net, name), nick)
    end
end

function H.NOTICE(chat, net, irc, msg)
    -- server notices belong to the snotice feature
    if msg[1] == '*' then return end
    H.PRIVMSG(chat, net, irc, msg)
end

function H.TAGMSG(chat, net, irc, msg)
    local state = msg.tags['+typing']
    local nick = msg.nick
    if not (state and nick and msg[1]) or irc_model.is_me(irc, nick) then return end
    local _, target = irc_model.split_statusmsg(irc, msg[1])
    local buffer
    if irc_model.is_channel_name(irc, target) then
        buffer = chat.buffer(net, target)
    elseif irc_model.is_me(irc, target) then
        buffer = chat.buffer(net, nick)
    end
    if not buffer then return end
    local timeout = M.timeout[state]
    if timeout then
        buffer.typing = buffer.typing or {}
        local key = chat.fold(net, nick)
        local old = buffer.typing[key]
        local now = clock.now()
        local changed = now
        if old and old.state == state and now < old.expires then
            changed = old.changed
        end
        buffer.typing[key] = {nick = nick, state = state, changed = changed, expires = now + timeout}
    else
        -- done, or a state the spec may add later
        stop_typing(chat, net, buffer, nick)
    end
end

-- Leaving a channel ends typing there; our own leaving ends all of it
local function left(chat, net, irc, channel, nick)
    local buffer = chat.buffer(net, channel)
    if not buffer then return end
    if irc_model.is_me(irc, nick) then
        buffer.typing = nil
    else
        stop_typing(chat, net, buffer, nick)
    end
end

function H.PART(chat, net, irc, msg)
    left(chat, net, irc, msg[1], msg.nick)
end

function H.KICK(chat, net, irc, msg)
    left(chat, net, irc, msg[1], msg[2])
end

-- QUIT and NICK carry the channels the user was in (net/handlers.lua)
function H.QUIT(chat, net, _, msg)
    for _, name in ipairs(msg.channels or {}) do
        stop_typing(chat, net, chat.buffer(net, name), msg.nick)
    end
    stop_typing(chat, net, msg.nick and chat.buffer(net, msg.nick), msg.nick)
end

-- A nick's typing, carried over to its new nick
local function rename_typing(chat, net, buffer, old, new)
    local entry = buffer and buffer.typing and buffer.typing[chat.fold(net, old)]
    if not entry then return end
    buffer.typing[chat.fold(net, old)] = nil
    entry.nick = new
    buffer.typing[chat.fold(net, new)] = entry
end

-- Before chat renames the private buffer, which it does unless one for
-- the new nick exists too
function H.NICK(chat, net, _, msg)
    if not msg.nick then return end
    for _, name in ipairs(msg.channels or {}) do
        rename_typing(chat, net, chat.buffer(net, name), msg.nick, msg[1])
    end
    local query, other = chat.buffer(net, msg.nick), chat.buffer(net, msg[1])
    if other and other ~= query then
        -- the buffers stay apart, and the nick's typing belongs in the
        -- other one
        stop_typing(chat, net, query, msg.nick)
    else
        rename_typing(chat, net, query, msg.nick, msg[1])
    end
end

--- Follow a message from the network, before chat handles it.
---@param chat hub.ChatLookup
---@param net string
---@param irc hub.Irc
---@param msg hub.Message
function M.handle(chat, net, irc, msg)
    local h = H[msg.command]
    if h then
        h(chat, net, irc, msg)
    end
end

return M
