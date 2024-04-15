local scrub = require 'utils.scrub'

local irc_colors = {
    [0] = ncurses.COLOR_WHITE, ncurses.COLOR_BLACK, ncurses.COLOR_BLUE, ncurses.COLOR_GREEN,
          ncurses.COLOR_RED, ncurses.COLOR_CYAN, ncurses.COLOR_MAGENTA, ncurses.COLOR_YELLOW,
          ncurses.COLOR_WHITE, ncurses.COLOR_BLACK, ncurses.COLOR_BLUE, ncurses.COLOR_GREEN,
          ncurses.COLOR_RED, ncurses.COLOR_CYAN, ncurses.COLOR_MAGENTA, ncurses.COLOR_YELLOW,
    [99] = ncurses.COLOR_DEFAULT,
}

return function(str)
    local on_b, on_b_
    local on_u, on_u_
    local on_r, on_r_
    local on_i, on_i_
    local background

    local function init()
        on_b, on_b_ = bold,         bold_
        on_u, on_u_ = underline,    underline_
        on_r, on_r_ = reversevideo, reversevideo_
        on_i, on_i_ = italic,       italic_
        background = nil
        normal()
    end

    init()

    while str ~= '' do
        local prefix, ctrl
        prefix, ctrl, str = string.match(str, '^([^\x00-\x1f\x7f]*)(.?)(.*)$')

        if prefix ~= '' then
            addstr(prefix)
        end

        -- done
        if ctrl == '' then
            normal()
            return

        -- ^B - bold
        elseif ctrl == '\x02' then
            on_b()
            on_b, on_b_ = on_b_, on_b

        -- ^O - reset
        elseif ctrl == '\x0f' then
            init()

        -- ^C - color
        elseif ctrl == '\x03' then
            local fore, back, rest = string.match(str, '^(%d%d?),(%d%d?)(.*)$')
            if fore == nil then
                fore, str = string.match(str, '^(%d?%d?)(.*)$')
            else
                str = rest
            end

            local foreground = math.tointeger(fore)
            if fore == '' then
                background = nil
            elseif back ~= nil then
                background = math.tointeger(back)
            end

            ncurses.colorset(irc_colors[foreground], irc_colors[background])

        -- ^_ - underline
        elseif ctrl == '\x1f' then
            on_u()
            on_u, on_u_ = on_u_, on_u

        -- ^V - reverse video
        elseif ctrl == '\x16' then
            on_r()
            on_r, on_r_ = on_r_, on_r

        -- ^] - italic
        elseif ctrl == '\x1d' then
            on_i()
            on_i, on_i_ = on_i_, on_i

        -- unsupported control character
        else
            addstr(scrub(ctrl))
        end
    end

    normal()
end
