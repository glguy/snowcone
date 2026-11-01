-- The formatting palette in the detail pane (Meta-P): buttons that put
-- IRC formatting codes into the line being typed, at the cursor, so no
-- one has to remember control characters or color numbers. Styles
-- toggle; a color sets the text or the background, as the switch says,
-- which shows both colors at the cursor. The first row shows the
-- formatting in effect there.
--
-- A color just before the cursor is changed rather than followed by
-- another, so a text color and a background picked one after the other
-- make one code, and picking again replaces the choice. Colors go in
-- with two digits, so a digit typed after one isn't read as part of its
-- number. A text color keeps the background, and a background the text
-- color, when the code needs both: before a comma, which would otherwise
-- be read as starting a background, and when changing a code that had
-- both.
-- Detail state: target, 'text' or 'background'.

local addircstr <const> = require 'hub.ui.irc_formatting'
local colors    <const> = require 'hub.ui.colors'
local control   <const> = require 'hub.ui.control'
local draw      <const> = require 'hub.ui.draw'
local editor    <const> = require 'hub.ui.editor'

local M = {kind = 'format'}

-- The usual names of IRC colors 0-15
local names <const> = {
    [0] = 'white', 'black', 'blue', 'green', 'red', 'brown', 'magenta', 'orange',
    'yellow', 'light green', 'cyan', 'light cyan', 'light blue', 'pink', 'grey', 'light grey',
}

-- Styles in the order of their buttons: name, code, and how the button
-- shows it (nil when the terminal can't)
local styles <const> = {
    {'bold',      '\x02', draw.bold},
    {'italic',    '\x1d', draw.italic},
    {'underline', '\x1f', draw.underline},
    {'strike',    '\x1e'},
    {'mono',      '\x11'},
    {'reverse',   '\x16', draw.reversevideo},
}
local style_of <const> = {}
for _, style in ipairs(styles) do style_of[style[2]] = style[1] end

local hex6 <const> = string.rep('%x', 6)

--- The formatting in effect after str: a style's name for each style on,
--- and fg and bg, an IRC color number or a hex string RRGGBB (nil for the
--- default, as is 99).
---@param str string
---@return table
function M.state_at(str)
    local s = {}
    local i = 1
    while true do
        local at, _, c = str:find('([\x02\x03\x04\x0f\x11\x16\x1d\x1e\x1f])', i)
        if not at then break end
        i = at + 1
        if style_of[c] then
            s[style_of[c]] = not s[style_of[c]] or nil
        elseif c == '\x0f' then
            s = {}
        else
            local digits = c == '\x03' and '%d%d?' or hex6
            local fore, back = str:match('^(' .. digits .. '),(' .. digits .. ')', i)
            if fore then
                i = i + #fore + 1 + #back
            else
                fore = str:match('^' .. digits, i)
                if fore then i = i + #fore end
            end
            if not fore then
                s.fg, s.bg = nil, nil
            else
                local function value(v)
                    if c == '\x04' then return v:upper() end
                    local n = tonumber(v)
                    if n ~= 99 then return n end
                end
                s.fg = value(fore)
                if back then s.bg = value(back) end
            end
        end
    end
    return s
end

-- A color in words
local function color_name(color)
    if type(color) == 'string' then return '#' .. color end
    return names[color] or ('color ' .. color)
end

--- The formatting of a state in words, and the codes that make it.
---@param s table from state_at
---@return string words
---@return string codes
local function describe(s)
    local words, codes = {}, {}
    for _, style in ipairs(styles) do
        if s[style[1]] then
            table.insert(words, style[1])
            table.insert(codes, style[2])
        end
    end
    -- only IRC color numbers here: the hex form isn't drawn as words
    local function irc(color) return type(color) == 'number' and color or 99 end
    if s.fg or s.bg then
        local color = s.fg and color_name(s.fg) or 'default'
        if s.bg then color = color .. ' on ' .. color_name(s.bg) end
        table.insert(words, color)
        local code = string.format('\x03%02d', irc(s.fg))
        if s.bg then code = code .. string.format(',%02d', irc(s.bg)) end
        table.insert(codes, code)
    end
    if not words[1] then return 'plain', '' end
    return table.concat(words, ', '), table.concat(codes)
end

-- The editor to put codes in, starting talk mode when nothing is being
-- typed; nil while typing a filter or a password, which take no
-- formatting
local function target_editor()
    local mode = HUB.state.ui.input.mode
    if mode == 'filter' or mode == 'password' then return nil end
    if not mode then control.set_input_mode 'talk' end
    return control.editor()
end

local function insert(code)
    local ed = target_editor()
    if ed then editor.insert(ed, code) end
end

-- The code for color n (99 for the default) as text or background, given
-- the formatting at the cursor; with_both writes both colors even for
-- the text
local function color_code(n, background, s, with_both)
    local function irc(color) return type(color) == 'number' and color or 99 end
    if background then
        return string.format('\x03%02d,%02d', irc(s.fg), n)
    elseif with_both then
        return string.format('\x03%02d,%02d', n, irc(s.bg))
    end
    return string.format('\x03%02d', n)
end

local function put_color(n, background)
    local ed = target_editor()
    if not ed then return end
    local before = ed.before_cursor
    local s = M.state_at(before)
    -- the color code right before the cursor, which this one replaces;
    -- the state already includes it
    local last = before:match '\x03%d%d?,%d%d?$' or before:match '\x03%d%d?$'
    local with_both = ed.at_cursor:sub(1, 1) == ',' or (last and last:find(',', 1, true)) ~= nil
    editor.insert(ed, color_code(n, background, s, with_both), last and #last)
end

-- Start a new row unless `width` more columns fit on this one
local function fit(win, cols, width)
    local _, x = ncurses.getyx(win)
    if x > 0 and x + width > cols then win:waddstr '\n' end
end

-- A swatch of IRC color n, `text` on it, which puts the color in
local function swatch(ctx, win, n, text, background)
    fit(win, ctx.cols, utf8.len(text) + 1)
    local count = ncurses.COLORS
    local fore = colors.light(n) and ncurses.COLOR_BLACK or ncurses.COLOR_WHITE
    ncurses.colorset(fore, colors.irc(n, count), win)
    ctx.add_button(win, text, function() put_color(n, background) end, true)
    draw.normal(win)
    win:waddstr ' '
end

function M.title()
    return 'formatting'
end

function M.render(ctx, win)
    local detail = ctx.vs
    local background = detail.target == 'background'
    local mode = HUB.state.ui.input.mode
    local ed = control.editor()

    -- what the cursor is in, drawn as it looks
    draw.blue(win)
    win:waddstr 'at the cursor: '
    draw.normal(win)
    if mode == 'filter' or mode == 'password' then
        win:waddstr('none while typing a ' .. mode)
    else
        local words, codes = describe(M.state_at(mode and ed.before_cursor or ''))
        addircstr(win, codes .. words)
        if not mode then
            draw.yellow(win)
            win:waddstr '  (a click starts a message to the shown buffer)'
            draw.normal(win)
        end
    end
    win:waddstr '\n'

    -- styles toggle; plain ends them all and the colors
    local s = mode and M.state_at(ed.before_cursor) or {}
    for _, style in ipairs(styles) do
        local name, code, show = style[1], style[2], style[3]
        fit(win, ctx.cols, #name + 3)
        -- on at the cursor in yellow, and each in its own style
        if s[name] then draw.yellow(win) end
        if show then show(win) end
        ctx.add_button(win, '[' .. name .. ']', function() insert(code) end, true)
        draw.normal(win)
        win:waddstr ' '
    end
    fit(win, ctx.cols, 7)
    ctx.add_button(win, '[plain]', function() insert '\x0f' end, true)
    win:waddstr '\n'

    -- what a color sets
    draw.blue(win)
    win:waddstr 'colors set: '
    draw.normal(win)
    local shown = {text = s.fg, background = s.bg}
    for _, choice in ipairs {'text', 'background'} do
        local on = (choice == 'background') == background
        local color = shown[choice]
        local label = string.format('[%s: %s]', choice, color and color_name(color) or 'default')
        if on then draw.green(win) end
        ctx.add_button(win, label, function() detail.target = choice end, not on)
        draw.normal(win)
        win:waddstr ' '
    end
    ctx.add_button(win, '[default]', function() put_color(99, background) end, true)
    win:waddstr '\n'

    -- the 16 named colors, then the rest in their hue and gray rows
    for n = 0, 15 do
        swatch(ctx, win, n, ' ' .. names[n] .. ' ', background)
    end
    win:waddstr '\n'
    for row = 0, 5 do
        for n = 16 + 12 * row, 27 + 12 * row do
            swatch(ctx, win, n, '  ', background)
        end
        win:waddstr '\n'
    end
    for n = 88, 98 do
        swatch(ctx, win, n, '  ', background)
    end
    win:waddstr '\n'
end

return M
