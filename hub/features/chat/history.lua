-- Chat history (CHATHISTORY) for chat's buffers: asked for when a buffer
-- opens and for every buffer after registration, and merged into the
-- buffer when its chathistory batch ends.
--
-- Server times are never compared: the history goes, in the server's
-- order, before the messages that arrived on the current connection
-- (those received since its registration), which puts it before
-- everything when a buffer opens and between the old and new messages
-- after a reconnect. Messages a buffer already has are skipped.
--
-- The functions take chat (features/chat), which requires this module.

local irc_model  <const> = require 'hub.net.irc'
local log        <const> = require 'hub.runtime.log'
local OrderedMap <const> = require 'hub.lib.OrderedMap'
local send       <const> = require 'hub.net.send'

local M = {}

local function query(net, ...)
    local ok, err = pcall(send.send, net, ...)
    if not ok then
        log.add_net(net, 'chat', '%s', err)
    end
end

--- Ask for a buffer's history, when the server has it and we are
--- registered: the messages BEFORE or the LATEST since `time` (a server
--- time tag), or without one the latest. At most a buffer's worth.
---@param chat hub.ChatLookup
---@param net string
---@param name string the buffer's target
---@param subcommand 'BEFORE'|'LATEST'
---@param time string|nil
function M.request(chat, net, name, subcommand, time)
    local rec = HUB.state.nets[net]
    local irc = rec and rec.irc
    if not (irc and irc_model.has_chathistory(irc)) then return end
    if rec.phase ~= 'connected' then return end
    local amount = chat.buffer_size
    if irc.max_chat_history and irc.max_chat_history < amount then
        amount = irc.max_chat_history
    end
    query(net, 'CHATHISTORY', subcommand, name, time and 'timestamp=' .. time or '*', amount)
end

--- After registration: the LATEST since the newest message of every
--- buffer but the wallops one.
---@param chat hub.ChatLookup
---@param net string
function M.after_registration(chat, net)
    for key, buffer in pairs(chat.get(net).buffers) do
        if key ~= chat.fold(net, chat.wallops) then
            local last = chat.newest(buffer)
            M.request(chat, net, buffer.name, 'LATEST', last and last.tags and last.tags.time)
        end
    end
end

-- Identity of a message, to spot one that history repeats. The server's
-- time is compared only as text.
local function message_key(msg)
    local id = msg.tags and msg.tags.msgid
    if id then return 'id ' .. id end
    local tags = msg.tags or {}
    return table.concat({tags.time or '', tostring(msg.source), tostring(msg.command), table.concat(msg, ' ')}, '\0')
end

--- Merge history into a buffer: before the messages received since
--- `since`, skipping those it has.
---@param chat hub.ChatLookup
---@param buffer hub.ChatBuffer
---@param messages hub.Message[]
---@param since number|nil clock.now() at registration
function M.merge(chat, buffer, messages, since)
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
            chat.insert(buffer, msg)
        end
    end
end

--- A chathistory batch (irc.batch), merged into the buffer it is for.
---@param chat hub.ChatLookup
---@param ev table the irc.batch event
function M.on_batch(chat, ev)
    local rec = HUB.state.nets[ev.net]
    local irc = rec and rec.irc
    local buffer = chat.buffer(ev.net, ev.params[1] or '')
    if not (irc and buffer) then return end
    for _, msg in ipairs(ev.messages) do
        if msg.command == 'PRIVMSG' or msg.command == 'NOTICE' then
            msg.statusmsg = irc_model.split_statusmsg(irc, msg[1])
        end
    end
    M.merge(chat, buffer, ev.messages, rec.registered_at)
end

return M
