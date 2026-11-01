-- Draw text with IRC formatting codes.

local colors <const> = require 'hub.ui.colors'
local draw   <const> = require 'hub.ui.draw'
local scrub  <const> = require 'hub.lib.scrub'

-- A color as sent, an IRC color number or a 0xRRGGBB value with this bit,
-- to the terminal's color; nil is the default
local HEX <const> = 0x1000000
local function terminal(color, count)
    if color == nil then return -1 end
    if color & HEX ~= 0 then return colors.rgb(color & ~HEX, count) end
    return colors.irc(color, count)
end

local hex6 <const> = string.rep('%x', 6)

--- Draw text with its formatting at the cursor.
---
--- With `edit`, for the line being typed: each control character shows
--- as its glyph (lib/scrub), drawn in the formatting it starts, so every
--- code point keeps a cell and the cursor moves over codes as over text.
--- Colors left at the default are edit.color. Returns the column of the
--- byte after the first edit.mark bytes, where the cursor goes.
---
--- With `wrap` (and no edit), the text wraps at spaces to continue at
--- column wrap.indent, as draw.wrap_text does.
---@param win ncurses.Window
---@param str string
---@param edit {mark: integer, color: integer}|nil
---@param wrap {cols: integer, indent: integer}|nil
---@return integer|nil
return function(win, str, edit, wrap)
    local on_b, on_b_
    local on_u, on_u_
    local on_r, on_r_
    local on_i, on_i_
    local foreground, background

    local default = edit and edit.color or -1
    local mark = edit and edit.mark
    local cursor_x
    local pos = 0 -- bytes of str drawn

    -- Different colors that come out the same on this terminal show the
    -- background as the default; the same color sent for both is meant to
    -- hide the text, and stays. 99 is the default too.
    local function set_colors()
        local count = ncurses.COLORS
        local fore = (foreground == nil or foreground == 99) and default or terminal(foreground, count)
        local back = terminal(background, count)
        if fore == back and foreground ~= background then
            back = -1
        end
        ncurses.colorset(fore, back, win)
    end

    local function init()
        on_b, on_b_ = draw.bold,         draw.bold_
        on_u, on_u_ = draw.underline,    draw.underline_
        on_r, on_r_ = draw.reversevideo, draw.reversevideo_
        on_i, on_i_ = draw.italic,       draw.italic_
        foreground, background = nil, nil
        draw.normal(win)
        if edit then set_colors() end
    end

    init()

    -- Text of str as it is, noting the cursor's column when it is inside;
    -- edit shows its controls, so it scrubs
    local function put(text)
        if mark and not cursor_x and mark < pos + #text then
            local k = mark - pos
            win:waddstr(scrub(text:sub(1, k)))
            cursor_x = select(2, ncurses.getyx(win))
            win:waddstr(scrub(text:sub(k + 1)))
        elseif edit then
            win:waddstr(scrub(text))
        elseif wrap then
            draw.wrap_text(win, text, wrap.cols, wrap.indent)
        else
            win:waddstr(text)
        end
        pos = pos + #text
    end

    -- A control character and its parameters, shown only with edit
    local function code(ctrl, params)
        if edit then
            if mark == pos and not cursor_x then
                cursor_x = select(2, ncurses.getyx(win))
            end
            win:waddstr(scrub(ctrl))
            pos = pos + 1
            if params ~= '' then put(params) end
        end
    end

    while str ~= '' do
        local prefix, ctrl
        prefix, ctrl, str = string.match(str, '^([^\x00-\x1f\x7f]*)(.?)(.*)$')

        if prefix ~= '' then
            put(prefix)
        end

        -- done
        if ctrl == '' then
            break

        -- ^B - bold
        elseif ctrl == '\x02' then
            on_b(win)
            on_b, on_b_ = on_b_, on_b
            code(ctrl, '')

        -- ^O - reset
        elseif ctrl == '\x0f' then
            init()
            code(ctrl, '')

        -- ^C - color: ^C, ^CN or ^CNN, then ,N or ,NN for the background
        elseif ctrl == '\x03' then
            local params, fore, back, rest = string.match(str, '^((%d%d?),(%d%d?))(.*)$')
            if fore == nil then
                fore, rest = string.match(str, '^(%d?%d?)(.*)$')
                params = fore
            end
            str = rest

            if fore == '' then
                foreground, background = nil, nil
            else
                foreground = tonumber(fore)
                if back ~= nil then
                    background = tonumber(back)
                end
            end
            set_colors()
            code(ctrl, params)

        -- ^D - hex color: as ^C, with RRGGBB for each color
        elseif ctrl == '\x04' then
            local params, fore, back, rest = string.match(str, '^((' .. hex6 .. '),(' .. hex6 .. '))(.*)$')
            if fore == nil then
                fore, rest = string.match(str, '^(' .. hex6 .. ')(.*)$')
                params = fore
            end
            if fore == nil then
                foreground, background = nil, nil
                params = ''
            else
                str = rest
                foreground = HEX | tonumber(fore, 16)
                if back ~= nil then
                    background = HEX | tonumber(back, 16)
                end
            end
            set_colors()
            code(ctrl, params)

        -- ^_ - underline
        elseif ctrl == '\x1f' then
            on_u(win)
            on_u, on_u_ = on_u_, on_u
            code(ctrl, '')

        -- ^V - reverse video
        elseif ctrl == '\x16' then
            on_r(win)
            on_r, on_r_ = on_r_, on_r
            code(ctrl, '')

        -- ^] - italic
        elseif ctrl == '\x1d' then
            on_i(win)
            on_i, on_i_ = on_i_, on_i
            code(ctrl, '')

        -- ^Q - monospace, ^^ - strikethrough: the terminal is already
        -- monospace, and ncurses has no strikethrough
        elseif ctrl == '\x11' or ctrl == '\x1e' then
            code(ctrl, '')

        -- unsupported control character
        elseif edit then
            code(ctrl, '')
        else
            win:waddstr(scrub(ctrl))
        end
    end

    if mark and not cursor_x then
        cursor_x = select(2, ncurses.getyx(win))
    end
    draw.normal(win)
    return cursor_x
end
