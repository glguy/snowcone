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

return function(win, str)
    local on_b, on_b_
    local on_u, on_u_
    local on_r, on_r_
    local on_i, on_i_
    local foreground, background

    local function init()
        on_b, on_b_ = draw.bold,         draw.bold_
        on_u, on_u_ = draw.underline,    draw.underline_
        on_r, on_r_ = draw.reversevideo, draw.reversevideo_
        on_i, on_i_ = draw.italic,       draw.italic_
        foreground, background = nil, nil
        draw.normal(win)
    end

    init()

    -- Different colors that come out the same on this terminal show the
    -- background as the default; the same color sent for both is meant to
    -- hide the text, and stays
    local function set_colors()
        local count = ncurses.COLORS
        local fore = terminal(foreground, count)
        local back = terminal(background, count)
        if fore == back and foreground ~= background then
            back = -1
        end
        ncurses.colorset(fore, back, win)
    end

    while str ~= '' do
        local prefix, ctrl
        prefix, ctrl, str = string.match(str, '^([^\x00-\x1f\x7f]*)(.?)(.*)$')

        if prefix ~= '' then
            win:waddstr(prefix)
        end

        -- done
        if ctrl == '' then
            draw.normal(win)
            return

        -- ^B - bold
        elseif ctrl == '\x02' then
            on_b(win)
            on_b, on_b_ = on_b_, on_b

        -- ^O - reset
        elseif ctrl == '\x0f' then
            init()

        -- ^C - color: ^C, ^CN or ^CNN, then ,N or ,NN for the background
        elseif ctrl == '\x03' then
            local fore, back, rest = string.match(str, '^(%d%d?),(%d%d?)(.*)$')
            if fore == nil then
                fore, str = string.match(str, '^(%d?%d?)(.*)$')
            else
                str = rest
            end

            if fore == '' then
                foreground, background = nil, nil
            else
                foreground = tonumber(fore)
                if back ~= nil then
                    background = tonumber(back)
                end
            end
            set_colors()

        -- ^D - hex color: as ^C, with RRGGBB for each color
        elseif ctrl == '\x04' then
            local fore, back, rest = string.match(str, '^(' .. hex6 .. '),(' .. hex6 .. ')(.*)$')
            if fore == nil then
                fore, rest = string.match(str, '^(' .. hex6 .. ')(.*)$')
            end
            if fore == nil then
                foreground, background = nil, nil
            else
                str = rest
                foreground = HEX | tonumber(fore, 16)
                if back ~= nil then
                    background = HEX | tonumber(back, 16)
                end
            end
            set_colors()

        -- ^_ - underline
        elseif ctrl == '\x1f' then
            on_u(win)
            on_u, on_u_ = on_u_, on_u

        -- ^V - reverse video
        elseif ctrl == '\x16' then
            on_r(win)
            on_r, on_r_ = on_r_, on_r

        -- ^] - italic
        elseif ctrl == '\x1d' then
            on_i(win)
            on_i, on_i_ = on_i_, on_i

        -- ^Q - monospace, ^^ - strikethrough: the terminal is already
        -- monospace, and ncurses has no strikethrough
        elseif ctrl == '\x11' or ctrl == '\x1e' then -- luacheck: ignore 542
            -- nothing to draw

        -- unsupported control character
        else
            win:waddstr(scrub(ctrl))
        end
    end

    draw.normal(win)
end
