-- The terminal: lending it to a child process, and whether it has focus.
--
-- Both live in HUB so a reload doesn't lose track of them: the count of
-- children holding the terminal, and focus as the UI last heard it.

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

---@return boolean # true while a child process has the terminal
function M.suspended()
    return (HUB.tty_suspended or 0) > 0
end

--- Record the terminal gaining or losing focus, as the UI hears it.
---@param on boolean
function M.set_focus(on)
    HUB.tty_unfocused = not on or nil
end

---@return boolean # true unless the terminal has said it lost focus;
--- always true without a UI
function M.focused()
    return not HUB.tty_unfocused
end

return M
