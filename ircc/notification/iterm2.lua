local scrub = require 'utils.scrub'

local M = {}

-- https://iterm2.com/documentation-escape-codes.html
-- OSC 9 ; [Message content goes here] ST
function M.notify(_, buffer, nick, msg)
    io.stdout:write('\x1b]9;' .. scrub(buffer) .. ' <' .. scrub(nick) .. '> ' .. scrub(msg) .. '\x07')
    io.stdout:flush()
    return true
end

function M.dismiss()
end

return M
