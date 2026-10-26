-- Lending the terminal to a child process.
--
-- The count lives in HUB so a reload while a child holds the terminal
-- doesn't lose track of it.

local dispatch <const> = require 'hub.runtime.dispatch'

local M = {}

function M.suspend()
    local n = HUB.tty_suspended or 0
    if n == 0 then
        snowcone.stop_input()
    end
    HUB.tty_suspended = n + 1
end

function M.resume()
    local n = (HUB.tty_suspended or 0) - 1
    HUB.tty_suspended = n
    if n == 0 then
        snowcone.start_input()
        dispatch.dirty()
    end
end

---@return boolean true while a child process has the terminal
function M.suspended()
    return (HUB.tty_suspended or 0) > 0
end

return M
