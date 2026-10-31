-- Our own PRIVMSG and NOTICE lines in chat's buffers, and their receipt.
--
-- With labeled-response (net/send.lua labels chat lines) our message in a
-- buffer has msg.receipt: 'awaiting' until the reply, then 'received' on
-- its echo (whose msgid and time it takes) or ACK, 'rejected' on an error
-- (msg.rejection holds its text), or 'unknown' if the reply never settled
-- it. The echo itself isn't shown again.
--
-- Lines awaiting their reply live in C.pending (hub.ChatState). Chat
-- requires this module, so it passes itself in for folding, finding and
-- keying buffers, and calls on_reply on each message before anything
-- else.

local irc_model  <const> = require 'hub.net.irc'
local OrderedMap <const> = require 'hub.lib.OrderedMap'

local M = {}

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
    local id = echo.tags and echo.tags.msgid
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

--- A message of the reply to one of our labeled lines: an echo, ACK or
--- error, alone or in a labeled batch. True for an echo, which is shown
--- already.
---@param chat hub.ChatLookup
---@param net string
---@param irc hub.Irc
---@param msg hub.Message
---@return boolean
function M.on_reply(chat, net, irc, msg)
    local C = chat.get(net)
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
        return false -- its end settles the reply (on_batch_end)
    elseif (command == 'PRIVMSG' or command == 'NOTICE') and irc_model.is_me(irc, msg.nick) then
        echo = true
        local entry = msg[1] and entries[chat.fold(net, msg[1])]
        if entry then received(entry, msg) end
    elseif command == 'ACK' then
        for _, entry in pairs(entries) do received(entry) end
    else
        -- an error about one target (ERR_NOSUCHNICK), or about them all
        local entry = msg[2] and entries[chat.fold(net, msg[2])]
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

--- Our own PRIVMSG or NOTICE (irc.sent), shown where it went; a labeled
--- one awaits its reply.
---@param chat hub.ChatLookup
---@param net string
---@param irc hub.Irc
---@param msg hub.Message
function M.on_sent(chat, net, irc, msg)
    if not msg[1] then return end
    local label = msg.tags.label
    local entries = {}
    local targets = {}
    for target in msg[1]:gmatch '[^,]+' do table.insert(targets, target) end
    for _, target in ipairs(targets) do
        local prefix, name = irc_model.split_statusmsg(irc, target)
        local buffer = chat.buffer(net, name)
        local copy = msg
        -- the console keeps the line as sent, and each target's echo
        -- brings its own msgid and text
        if prefix or label or #targets > 1 then
            copy = {} --[[@as hub.Message]]
            for k, v in pairs(msg) do copy[k] = v end
            copy.tags = {}
            for k, v in pairs(msg.tags) do copy.tags[k] = v end
            copy.statusmsg = prefix
        end
        if label then
            copy.receipt = 'awaiting'
            -- without a buffer it is still awaited, so its echo is known
            entries[chat.fold(net, target)] = {msg = copy, buffer = buffer}
        end
        if buffer then
            chat.insert(buffer, copy)
        end
    end
    if label then
        chat.get(net).pending[label] = entries
    end
end

--- A labeled batch (irc.batch) has ended: its reply is over.
---@param chat hub.ChatLookup
---@param net string
---@param label string|nil
function M.on_batch_end(chat, net, label)
    local C = chat.get(net)
    if label and C.pending[label] then
        settle(C, label)
    end
end

--- The connection is over, and so is every reply; labels start again on
--- the next one.
---@param C hub.ChatState
function M.settle_all(C)
    for label in pairs(C.pending) do settle(C, label) end
end

return M
