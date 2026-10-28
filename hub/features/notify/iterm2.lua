-- Notification by iTerm2's OSC 9 escape.
-- https://iterm2.com/documentation-escape-codes.html

local scrub <const> = require 'hub.lib.scrub'

local M = {}

function M.notify(_, buffer, nick, msg)
    io.stdout:write('\x1b]9;' .. scrub(buffer) .. ' <' .. scrub(nick) .. '> ' .. scrub(msg) .. '\x07')
    io.stdout:flush()
    return true
end

function M.dismiss() end

return M
