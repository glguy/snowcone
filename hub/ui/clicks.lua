-- Click regions, rebuilt every frame, and the hit test for a click.
--
-- What a button does shows in how it looks. One that sets a mode, a
-- setting or a choice, or runs an action, is a chip (M.chip): its label
-- on a color of its role, or in brackets on the classic theme, [+], [↻],
-- [4h]. Choices of one setting are one control with a segment each
-- (M.segments), the one in effect lit: [summary|message|raw] on the
-- classic theme. One that goes somewhere else, another view, buffer or
-- detail, is plain and starts with an arrow: →console, ←BACK, ↩. A name
-- that shows its own thing (a nick, a channel, a network) is plain text.
--
-- The regions hold functions, so they live here and not in HUB.state;
-- a new generation starts without them and rebuilds them on its first
-- draw.

local draw  <const> = require 'hub.ui.draw'
local theme <const> = require 'hub.ui.theme'

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

---@alias hub.ChipRole 'neutral'|'accent'|'ok'|'warn'|'danger'

--- Draw `text` at the cursor in colors and attributes, then put back the
--- ones the window had.
local function put(win, text, fore, back)
    local attrs, pair = ncurses.attrget(win)
    ncurses.colorset(fore, back, win)
    win:waddstr(text)
    ncurses.attrset(attrs, pair, win)
end

--- The columns a chip of `label` takes: two more than the label, on
--- either theme.
---@param label string
---@return integer
function M.chip_width(label)
    return (utf8.len(label) or #label) + 2
end

--- Draw a chip of `label` at the cursor, of a role (neutral when not
--- given), and make it clickable: on the modern theme the label padded on
--- a color of its role, or between caps with glyphs that have them; on
--- the classic, in brackets in reverse video, in the role's color but for
--- neutral, which keeps the color set.
---@param win ncurses.Window
---@param label string
---@param action fun(shifted: boolean|nil)
---@param role hub.ChipRole|nil
function M.chip(win, label, action, role)
    role = role or 'neutral'
    local y1, x1 = ncurses.getyx(win)
    local fore, back = theme.chip(role)
    if fore then
        local glyphs = theme.glyphs()
        local _, base = draw.base(win)
        if glyphs.cap_left then
            put(win, glyphs.cap_left, back, base)
            put(win, label, fore, back)
            put(win, glyphs.cap_right, back, base)
        else
            put(win, ' ' .. label .. ' ', fore, back)
        end
    else
        local attrs, pair = ncurses.attrget(win)
        local color = theme.classic_chip[role]
        if color then draw[color](win) end
        draw.reversevideo(win)
        win:waddstr('[', label, ']')
        ncurses.attrset(attrs, pair, win)
    end
    local _, x2 = ncurses.getyx(win)
    M.add(y1, x1, x2, action)
end

--- Draw the gap between two chips side by side: a space, but for chips
--- between caps (rounded glyphs on the modern theme), whose caps part them.
---@param win ncurses.Window
function M.chip_gap(win)
    if M.gap_width() > 0 then win:waddstr ' ' end
end

--- The columns chip_gap takes.
---@return integer
function M.gap_width()
    return (theme.modern() and theme.glyphs().cap_left) and 0 or 1
end

--- Draw choices of one setting at the cursor as one control, a segment
--- each, clickable, the one `on` lit: on the modern theme, adjacent chips,
--- the lit one in the accent color; on the classic, [a|b|c] with the lit
--- one in reverse video.
---@param win ncurses.Window
---@param segments {label: string, action: fun(shifted: boolean|nil), on: boolean|nil}[]
function M.segments(win, segments)
    local glyphs = theme.glyphs()
    local _, base = draw.base(win)
    for i, seg in ipairs(segments) do
        local y1, x1 = ncurses.getyx(win)
        local fore, back = theme.chip(seg.on and 'accent' or 'neutral')
        if fore then
            local first, last = i == 1, i == #segments
            if first and glyphs.cap_left then put(win, glyphs.cap_left, back, base) end
            put(win, (first and glyphs.cap_left) and seg.label or ' ' .. seg.label, fore, back)
            if last and glyphs.cap_right then
                put(win, glyphs.cap_right, back, base)
            else
                put(win, ' ', fore, back)
            end
        else
            win:waddstr(i == 1 and '[' or '|')
            _, x1 = ncurses.getyx(win)
            if seg.on then draw.reversevideo(win) end
            win:waddstr(seg.label)
            if seg.on then draw.reversevideo_(win) end
        end
        local _, x2 = ncurses.getyx(win)
        M.add(y1, x1, x2, seg.action)
    end
    if #segments > 0 and not theme.modern() then win:waddstr ']' end
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
