-- The terminal: lending it to a child process, whether it has focus, and
-- its window title.
--
-- All live in HUB so a reload doesn't lose track of them: the count of
-- children holding the terminal, focus as the UI last heard it, and the
-- title last written.

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
        -- the child may have set a title of its own
        M.forget_title()
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

--- Set the window title and icon name (OSC 0), unless it is the one last
--- written. The native side saves the titles it found and restores them at
--- exit.
---@param title string scrubbed of control characters (hub.lib.scrub),
--- C1 included
function M.set_title(title)
    if HUB.tty_title == title then return end
    HUB.tty_title = title
    snowcone.set_title(title)
end

--- Forget the title last written, so the next set_title writes it even
--- if it is the same: for when something else may have changed it.
function M.forget_title()
    HUB.tty_title = nil
end

return M
