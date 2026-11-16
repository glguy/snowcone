-- The text of a chat message as it is matched and quoted: mention
-- patterns, hide rules, filters and notifications all see it without IRC
-- formatting, and an action (CTCP ACTION, /me) without its framing.

local strip_formatting <const> = require 'hub.lib.strip_formatting'

local M = {}

--- An action's text without its CTCP framing, whose closing \x01 may be
--- missing; nil when the text is not an action.
---@param text string
---@return string|nil
function M.action(text)
    return text:match '^\x01ACTION (.-)\x01?$'
end

--- Text as it is matched: an action's without its framing, and without
--- formatting.
---@param text string
---@return string
function M.plain(text)
    return strip_formatting(M.action(text) or text)
end

--- A PRIVMSG's or NOTICE's text as it is matched (M.plain); nil for
--- other commands.
---@param msg hub.Message
---@return string|nil
function M.of(msg)
    if msg.command ~= 'PRIVMSG' and msg.command ~= 'NOTICE' then return nil end
    return M.plain(msg[2] or '')
end

return M
