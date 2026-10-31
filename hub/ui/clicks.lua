-- Click regions, rebuilt every frame, and the hit test for a click.
--
-- The regions hold functions, so they live here and not in HUB.state;
-- a new generation starts without them and rebuilds them on its first
-- draw.

local draw <const> = require 'hub.ui.draw'

local M = {}

-- pending[y] = {{lo, hi, action}, ...} for the part being drawn, and
-- shown[y] the same in screen rows. Each part of the screen records its
-- clicks in the rows of the window it draws into, and place moves them to
-- screen rows in shown.
local pending = {}
local shown = {}

--- Forget every region, for a new frame.
function M.reset()
    pending, shown = {}, {}
end

--- Forget the regions of the part being drawn, to draw it again.
function M.restart()
    pending = {}
end

--- Move the clicks on rows [first, first + count) of the part just drawn
--- to screen rows from `at`, and left by the columns `hscroll` scrolls
--- past, and start the next part.
---@param first integer
---@param count integer
---@param at integer
---@param hscroll integer|nil
function M.place(first, count, at, hscroll)
    hscroll = hscroll or 0
    for row, list in pairs(pending) do
        if first <= row and row < first + count then
            for _, entry in ipairs(list) do
                entry.lo, entry.hi = entry.lo - hscroll, entry.hi - hscroll
            end
            shown[row - first + at] = list
        end
    end
    pending = {}
end

--- Make columns [lo, hi) of row y of the part being drawn clickable.
---@param y integer
---@param lo integer
---@param hi integer
---@param action fun(shifted: boolean|nil)
function M.add(y, lo, hi, action)
    local list = pending[y]
    local entry = {lo = lo, hi = hi, action = action}
    if list then
        table.insert(list, entry)
    else
        pending[y] = {entry}
    end
end

--- Draw `text` at the cursor, in reverse video unless `plain`, and make
--- it clickable.
---@param win ncurses.Window
---@param text string
---@param action fun(shifted: boolean|nil)
---@param plain boolean|nil
function M.button(win, text, action, plain)
    local y1, x1 = ncurses.getyx(win)
    if not plain then draw.reversevideo(win) end
    win:waddstr(text)
    if not plain then draw.reversevideo_(win) end
    local _, x2 = ncurses.getyx(win)
    M.add(y1, x1, x2, action)
end

--- Run the actions of the regions shown at screen row y, column x.
---@param y integer
---@param x integer
---@param shifted boolean
---@return boolean hit whether any ran
function M.hit(y, x, shifted)
    local hit = false
    for _, button in ipairs(shown[y] or {}) do
        if button.lo <= x and x < button.hi then
            button.action(shifted)
            hit = true
        end
    end
    return hit
end

return M
