-- What the user wants a network's session to be, kept across connections
-- so that a new connection restores it: the nick, the channels we are in
-- with their keys, and our away message.
--
-- The protocol model (net/irc.lua) says what the current connection is;
-- this says what any connection should become. It is rec.intent, made
-- with the network's record and changed only by what we do: our own
-- NICK through /nick, our JOIN, PART and KICK, keys we send or see set,
-- and AWAY lines we send. Registration replays it (net/registration.lua).
--
-- Names are kept as given and folded with the connection's casemapping
-- when compared, as the casemapping can change between connections.

local casemap   <const> = require 'hub.lib.casemap'
local irc_model <const> = require 'hub.net.irc'

local M = {}

---@class hub.IntentChannel
---@field name string as joined
---@field key string|nil the key to join with

---@class hub.Intent
---@field nick string|nil the nick last given to /nick, until the configured
--- nick changes
---@field channels hub.IntentChannel[] channels we are in, or were in when
--- the connection ended, in the order joined
---@field keys table<string, string> keys sent with a JOIN that hasn't
--- come back yet, by name as sent
---@field away string|nil our away message, nil when here

---@return hub.Intent
function M.new()
    return {channels = {}, keys = {}}
end

--- A network's intent, made on first use; one made for a record from
--- before intents starts from its /nick and the channels it is in.
---@param rec hub.Network
---@return hub.Intent
function M.of(rec)
    local intent = rec.intent
    if intent == nil then
        intent = M.new()
        rec.intent = intent
        intent.nick = rec.wanted_nick
        rec.wanted_nick = nil
        local irc = rec.irc
        if irc then
            for _, channel in pairs(irc.channels) do
                table.insert(intent.channels, {name = channel.name})
            end
            table.sort(intent.channels, function(a, b) return a.name < b.name end)
        end
    end
    return intent
end

-- Fold with the connection's casemapping, or rfc1459 without one
local function fold(irc, name)
    return irc and irc_model.fold(irc, name) or casemap.fold('rfc1459', name)
end

-- The index of a channel in the intent, or nil
local function find(intent, irc, name)
    local key = fold(irc, name)
    for i, channel in ipairs(intent.channels) do
        if fold(irc, channel.name) == key then return i end
    end
end

-- A key sent for a channel, taken out of the pending keys
local function take_key(intent, irc, name)
    local key = fold(irc, name)
    for sent, k in pairs(intent.keys) do
        if fold(irc, sent) == key then
            intent.keys[sent] = nil
            return k
        end
    end
end

--- Our JOIN came back: the channel is wanted, with the key we sent.
---@param rec hub.Network
---@param irc hub.Irc
---@param name string
function M.joined(rec, irc, name)
    local intent = M.of(rec)
    local key = take_key(intent, irc, name)
    local i = find(intent, irc, name)
    if i then
        local channel = intent.channels[i]
        channel.name = name
        channel.key = key or channel.key
    else
        table.insert(intent.channels, {name = name, key = key})
    end
end

--- We left a channel (PART, KICK), or closed its buffer: not wanted.
---@param rec hub.Network
---@param irc hub.Irc|nil
---@param name string
function M.left(rec, irc, name)
    local intent = M.of(rec)
    local i = find(intent, irc, name)
    if i then table.remove(intent.channels, i) end
end

--- A channel's key changed while we are in it: false when removed.
---@param rec hub.Network
---@param irc hub.Irc
---@param name string
---@param key string|false
function M.channel_key(rec, irc, name, key)
    local intent = M.of(rec)
    local i = find(intent, irc, name)
    if i then
        intent.channels[i].key = key or nil
    end
end

--- The channels a new connection joins: those we were in, then
--- configured ones that ask to be joined. A wanted channel's key is the
--- one it was joined with, else the configured one.
---@param rec hub.Network
---@param irc hub.Irc
---@return hub.IntentChannel[]
function M.channels(rec, irc)
    local intent = M.of(rec)
    local list, seen, configured = {}, {}, {}
    for _, buffer in ipairs(rec.cfg.buffers or {}) do
        configured[fold(irc, buffer.name)] = buffer
    end
    for _, channel in ipairs(intent.channels) do
        local key = fold(irc, channel.name)
        if not seen[key] then
            seen[key] = true
            local buffer = configured[key]
            table.insert(list, {name = channel.name, key = channel.key or buffer and buffer.key})
        end
    end
    for _, buffer in ipairs(rec.cfg.buffers or {}) do
        local key = fold(irc, buffer.name)
        if buffer.join and not seen[key] then
            seen[key] = true
            table.insert(list, {name = buffer.name, key = buffer.key})
        end
    end
    return list
end

-- Lines we send =======================================================

local function join_sent(intent, chans, keys)
    if not (chans and keys) then return end
    local names = {}
    for name in chans:gmatch '[^,]+' do table.insert(names, name) end
    local i = 0
    for key in keys:gmatch '[^,]+' do
        i = i + 1
        if names[i] then intent.keys[names[i]] = key end
    end
end

--- Note what a line we send says we want: keys from JOIN, our away
--- message from AWAY.
---@param rec hub.Network
---@param cmd string|integer
---@param args string[] the arguments, as sent
function M.sent(rec, cmd, args)
    cmd = tostring(cmd):upper()
    if cmd == 'JOIN' then
        join_sent(M.of(rec), args[1], args[2])
    elseif cmd == 'AWAY' then
        local text = args[1]
        M.of(rec).away = text ~= nil and text ~= '' and text or nil
    end
end

--- As sent, for a line sent as typed: its words, the last after ':'.
---@param rec hub.Network
---@param text string
function M.sent_raw(rec, text)
    local line = text:gsub('^@%S*%s*', '')
    local head, trailing = line:match '^(.-) :(.*)$'
    if not head then head = line end
    local words = {}
    for word in head:gmatch '%S+' do table.insert(words, word) end
    if trailing then table.insert(words, trailing) end
    local cmd = table.remove(words, 1)
    if cmd then M.sent(rec, cmd, words) end
end

return M
