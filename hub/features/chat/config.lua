-- What the configuration says of chat's buffers: a buffer's own settings
-- ([[networks.buffers]]), matched by name as the network folds it, and
-- the mention settings that apply to it.

local casemap    <const> = require 'hub.lib.casemap'
local luapattern <const> = require 'hub.lib.luapattern'
local regex      <const> = require 'hub.lib.regex'
local store      <const> = require 'hub.features.chat.store'

local M = {}

--- Mention settings ([mention], [networks.mention], a buffer's mention):
--- Lua patterns and PCRE2 regular expressions. A message matching any
--- of either is a mention.
---@class hub.MentionSettings
---@field patterns string[]|nil
---@field regexes string[]|nil

--- A configured buffer ([[networks.buffers]]), as validated by
--- runtime/config_schema.lua and M.check.
---@class hub.BufferSettings
---@field name string the channel or nick, folded by the network's casemapping to match
---@field join boolean|nil JOIN after every registration
---@field key string|nil the channel key to join with
---@field mention hub.MentionSettings|nil the buffer's own mention settings
---@field activity boolean|nil false: only mentions mark the buffer unseen
---@field label string|false|nil the jump pane key, one letter or digit; false for none
---@field hidden boolean|nil left out of the jump pane

-- Mention settings' patterns must be well formed, and their regexes
-- compile, so they need rex_pcre2
local function check_mention(mention, where)
    for i, pattern in ipairs(mention and mention.patterns or {}) do
        local err = luapattern.check(pattern)
        if err then
            error(string.format('%s.patterns.%d: %s', where, i, err), 0)
        end
    end
    for i, source in ipairs(mention and mention.regexes or {}) do
        local err = regex.check(source)
        if err then
            error(string.format('%s.regexes.%d: %s', where, i, err), 0)
        end
    end
end

--- Check the mention settings and buffers of a configuration as it loads.
---@param cfg table
function M.check(cfg)
    check_mention(cfg.mention, 'mention')
    for _, net in ipairs(cfg.networks) do
        check_mention(net.mention, string.format('networks.%s.mention', net.id))
        -- names alike in ASCII case are alike in every casemapping
        local names, labels = {}, {}
        for n, buffer in ipairs(net.buffers or {}) do
            local key = casemap.fold('ascii', buffer.name)
            if names[key] then
                error(string.format('networks.%s.buffers.%d: %s is already buffers.%d',
                    net.id, n, buffer.name, names[key]), 0)
            end
            names[key] = n
            check_mention(buffer.mention, string.format('networks.%s.buffers.%d.mention', net.id, n))
            local key_label = buffer.label
            if key_label == true then
                error(string.format('networks.%s.buffers.%d.label: a letter or digit, or false for none', net.id, n), 0)
            elseif key_label then
                if labels[key_label] then
                    error(string.format('networks.%s.buffers.%d.label: %s is already the label of buffers.%d',
                        net.id, n, key_label, labels[key_label]), 0)
                end
                labels[key_label] = n
            end
        end
    end
end

-- The configured buffers by folded name, for a network's `buffers` and
-- the casemapping they were folded with, rebuilt when either changes
local settings_index = setmetatable({}, {__mode = 'k'})

--- The configured settings of a buffer ([[networks.buffers]]), if any.
---@param net string
---@param target string
---@return hub.BufferSettings|nil
function M.settings(net, target)
    local rec = HUB.state.nets[net]
    local buffers = rec and rec.cfg.buffers
    if not buffers or #buffers == 0 then return end
    -- the casemappings fold these differently, so this tells them apart
    local probe = store.fold(net, '[]\\~')
    local index = settings_index[buffers]
    if not index or index.probe ~= probe then
        index = {probe = probe, by_name = {}}
        for _, buffer in ipairs(buffers) do
            index.by_name[store.fold(net, buffer.name)] = buffer
        end
        settings_index[buffers] = index
    end
    return index.by_name[store.fold(net, target)]
end

-- Whether mention settings set anything; ones that don't leave the
-- level below in place
local function sets(mention)
    return mention ~= nil and (mention.patterns ~= nil or mention.regexes ~= nil)
end

--- A buffer's own mention settings, if it sets patterns or regexes.
---@param net string
---@param target string
---@return hub.MentionSettings|nil
function M.own_mention(net, target)
    local settings = M.settings(net, target)
    local mention = settings and settings.mention
    if sets(mention) then return mention end
    return nil
end

--- The mention settings for a buffer: its own, else the network's, else
--- the global ones. Whichever level sets patterns or regexes replaces
--- both lists of the levels below it.
---@param net string
---@param target string
---@return hub.MentionSettings|nil
function M.mention(net, target)
    local own = M.own_mention(net, target)
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
