-- What the configuration says of chat's buffers: a buffer's own settings
-- ([[networks.buffers]]), matched by name as the network folds it, and
-- the mention settings that apply to it.
--
-- The functions take chat (features/chat), which requires this module.

local regex <const> = require 'hub.lib.regex'

local M = {}

--- Mention settings ([mention], [networks.mention], a buffer's mention):
--- Lua patterns and PCRE2 regular expressions. A message matching any
--- of either is a mention.
---@class hub.MentionSettings
---@field patterns string[]|nil
---@field regexes string[]|nil

--- A configured buffer ([[networks.buffers]]), as validated by
--- runtime/config_schema.lua and runtime/config.lua.
---@class hub.BufferSettings
---@field name string the channel or nick, folded by the network's casemapping to match
---@field join boolean|nil JOIN after every registration
---@field key string|nil the channel key to join with
---@field mention hub.MentionSettings|nil the buffer's own mention settings
---@field activity boolean|nil false: only mentions mark the buffer unseen
---@field label string|false|nil the jump pane key, one letter or digit; false for none
---@field hidden boolean|nil left out of the jump pane

-- The configured buffers by folded name, for a network's `buffers` and
-- the casemapping they were folded with, rebuilt when either changes
local settings_index = setmetatable({}, {__mode = 'k'})

--- The configured settings of a buffer ([[networks.buffers]]), if any.
---@param chat hub.ChatLookup
---@param net string
---@param target string
---@return hub.BufferSettings|nil
function M.settings(chat, net, target)
    local rec = HUB.state.nets[net]
    local buffers = rec and rec.cfg.buffers
    if not buffers or #buffers == 0 then return end
    -- the casemappings fold these differently, so this tells them apart
    local probe = chat.fold(net, '[]\\~')
    local index = settings_index[buffers]
    if not index or index.probe ~= probe then
        index = {probe = probe, by_name = {}}
        for _, buffer in ipairs(buffers) do
            index.by_name[chat.fold(net, buffer.name)] = buffer
        end
        settings_index[buffers] = index
    end
    return index.by_name[chat.fold(net, target)]
end

-- Whether mention settings set anything; ones that don't leave the
-- level below in place
local function sets(mention)
    return mention ~= nil and (mention.patterns ~= nil or mention.regexes ~= nil)
end

--- A buffer's own mention settings, if it sets patterns or regexes.
---@param chat hub.ChatLookup
---@param net string
---@param target string
---@return hub.MentionSettings|nil
function M.own_mention(chat, net, target)
    local settings = M.settings(chat, net, target)
    local mention = settings and settings.mention
    if sets(mention) then return mention end
    return nil
end

--- The mention settings for a buffer: its own, else the network's, else
--- the global ones. Whichever level sets patterns or regexes replaces
--- both lists of the levels below it.
---@param chat hub.ChatLookup
---@param net string
---@param target string
---@return hub.MentionSettings|nil
function M.mention(chat, net, target)
    local own = M.own_mention(chat, net, target)
    if own then return own end
    local rec = HUB.state.nets[net]
    local network = rec and rec.cfg.mention
    if sets(network) then return network end
    local global = HUB.state.config and HUB.state.config.mention
    if sets(global) then return global end
    return nil
end

--- Whether text matches any of the mention settings' Lua patterns or
--- regular expressions; a malformed one matches nothing. Chat passes the
--- text without formatting or action framing (lib/message_text.lua).
---@param mention hub.MentionSettings|nil
---@param text string
---@return boolean
function M.matches(mention, text)
    if not mention then return false end
    for _, pattern in ipairs(mention.patterns or {}) do
        local ok, found = pcall(string.find, text, pattern)
        if ok and found then return true end
    end
    for _, source in ipairs(mention.regexes or {}) do
        if regex.find(source, text) then return true end
    end
    return false
end

return M
