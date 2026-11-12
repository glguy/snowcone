-- What the configuration says of chat's buffers: a buffer's own settings
-- ([[networks.buffers]]), matched by name as the network folds it, and
-- the mention patterns that apply to it.
--
-- The functions take chat (features/chat), which requires this module.

local M = {}

-- The configured buffers by folded name, for a network's `buffers` and
-- the casemapping they were folded with, rebuilt when either changes
local settings_index = setmetatable({}, {__mode = 'k'})

--- The configured settings of a buffer ([[networks.buffers]]), if any.
---@param chat hub.ChatLookup
---@param net string
---@param target string
---@return table|nil {name, join, level, label, hidden}
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

--- A buffer's own mention patterns (Lua patterns), if it has them.
---@param chat hub.ChatLookup
---@param net string
---@param target string
---@return string[]|nil
function M.own_patterns(chat, net, target)
    local settings = M.settings(chat, net, target)
    return settings and settings.mention and settings.mention.patterns
end

--- Mention patterns (Lua patterns) for a buffer: its own, else the
--- network's, else the global ones.
---@param chat hub.ChatLookup
---@param net string
---@param target string
---@return string[]
function M.mention_patterns(chat, net, target)
    local patterns = M.own_patterns(chat, net, target)
    if patterns then return patterns end
    local rec = HUB.state.nets[net]
    local own = rec and rec.cfg.mention
    if own and own.patterns then return own.patterns end
    local global = HUB.state.config and HUB.state.config.mention
    return global and global.patterns or {}
end

--- Whether text matches any of the patterns; a malformed pattern matches
--- nothing.
---@param patterns string[]
---@param text string
---@return boolean
function M.matches(patterns, text)
    for _, pattern in ipairs(patterns) do
        local ok, found = pcall(string.find, text, pattern)
        if ok and found then return true end
    end
    return false
end

return M
