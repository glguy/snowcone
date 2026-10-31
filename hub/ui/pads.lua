-- Drawing into pads that are taller or wider than the screen: the main
-- pad's width, growing a pad to hold a document, and paging it. Shared by
-- the layout (ui/init.lua) and the detail pane (ui/details/init.lua).

local clicks <const> = require 'hub.ui.clicks'
local draw   <const> = require 'hub.ui.draw'

local M = {}

-- Width of the main pad; views scroll horizontally across it, as a wide
-- detail does across the detail pane's
M.width = 550

-- Rows a document view's pad may grow to
local document_limit <const> = 4096

--- Draw everything, top to bottom, into a pad `width` columns wide that
--- doubles until it holds it all, or reaches the limit. Returns the rows
--- used, never past the limit, so a pad made taller than the limit (the
--- detail pane's rule goes below its content) doesn't grow with each draw.
---@param pad ncurses.Window
---@param width integer
---@param render_into fun(win: ncurses.Window)
---@return integer
function M.draw_grown(pad, width, render_into)
    local height, y, x
    local h, w = ncurses.getmaxyx(pad)
    if w ~= width then pad:wresize(h, width) end
    repeat
        clicks.restart()
        pad:werase()
        draw.normal(pad)
        render_into(pad)
        height = ncurses.getmaxyx(pad)
        y, x = ncurses.getyx(pad)
        -- a cursor on the last row may mean rows were lost
        local full = y >= height - 1 and height < document_limit
        if full then
            pad:wresize(math.min(height * 2, document_limit), width)
        end
    until not full
    return math.min(x > 0 and y + 1 or y, document_limit)
end

--- Record the page size and scroll limit of a document for the paging keys
--- (ui/keymap.lua), and keep its scroll in range.
---@param vs table
---@param used integer
---@param rows integer
function M.set_paging(vs, used, rows)
    vs.page = math.max(1, rows - 1)
    vs.max_scroll = math.max(0, used - rows)
    vs.scroll = math.max(0, math.min(vs.scroll, vs.max_scroll))
end

return M
