-- What a chat buffer holds: putting messages in and finding them, and
-- choosing among buffers.

local hide       <const> = require 'hub.features.chat.hide'
local irc_model  <const> = require 'hub.net.irc'
local OrderedMap <const> = require 'hub.lib.OrderedMap'
local store      <const> = require 'hub.features.chat.store'

local M = {}

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
    for key, buffer in pairs(store.get(net).buffers) do
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

--- A message's msgid, when it has one.
---@param msg hub.Message
---@return string|nil
function M.msgid(msg)
    return msg.tags and msg.tags.msgid
end

--- Put a message in a buffer. It is keyed by its msgid; ours, until its
--- echo brings one, by itself. Others are reached only by iteration. The hide rules classify
--- it first (chat/hide.lua), since the map asks the view's predicate
--- whether it is shown as it goes in.
---@param net string
---@param buffer hub.ChatBuffer
---@param msg hub.Message
function M.insert(net, buffer, msg)
    hide.classify(net, buffer, msg)
    local key = M.msgid(msg)
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

-- Whether a buffer holds a message: by its msgid when it has one, else
-- by searching
local function holds(buffer, msg)
    local id = M.msgid(msg)
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
    if not store.enabled(net) then return nil end
    local preferred = prefer and store.buffer(net, prefer)
    if preferred and holds(preferred, msg) then return preferred end
    local best, best_key
    for key, buffer in pairs(store.get(net).buffers) do
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
    local buffer = store.enabled(net) and store.buffer(net, target)
    if not buffer then return nil end
    local irc = store.model(net)
    for msg in OrderedMap.each(buffer.messages) do
        if msg.nick and (msg.command == 'PRIVMSG' or msg.command == 'NOTICE') then
            local found = nicks[store.fold(net, msg.nick)]
            if found and not (irc and irc_model.is_me(irc, msg.nick)) then return found end
        end
    end
    return nil
end

return M
