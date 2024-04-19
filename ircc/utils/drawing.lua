local addircstr = require 'utils.irc_formatting'
local matching = require 'utils.matching'
local scrub = require 'utils.scrub'

local divider_string =
--  00:00:00
           "········································································\z
    1···············································································\z
    2···············································································\z
    3···············································································\z
    4···············································································\z
    5···············································································\z
    6·····································································"

local scrolled_divider_string =
--  00:00:00
           "··↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·\z
    1·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·\z
    2·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·\z
    3·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·\z
    4·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·\z
    5·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·\z
    6·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·"

local M = {}

function M.fade_time(win, timestamp, time)
    local age = uptime - timestamp
    if age < 8 then
        white(win)
        win:waddstr(string.sub(time, 1, 8-age))
        cyan(win)
        win:waddstr(string.sub(time, 9-age, 8))
    else
        cyan(win)
        win:waddstr(time)
    end
end

local function rotating_window(source, rows, predicate)
    source.predicate = predicate

    -- When we're scrolling the rolling buffer doesn't add anything
    -- so the divider line is forced to the bottom of the screen
    -- the value of ticker is memorized when scroll starts so that
    -- the viewport stays fixed in place while scrolling
    local offset, divider
    if scroll > 0 then
        local pin = source.pin or source.ticker
        source.pin = pin
        offset = scroll + source.ticker - pin
        divider = rows - 1
    else
        source.pin = nil
        divider = source.ticker
        offset = 0
    end

    if rows <= 0 then return {} end

    local n = 0
    local window = {}

    for entry in source:each(offset) do
        if n+1 >= rows then break end -- saves a row for divider
        if not predicate or predicate(entry) then
            window[(divider-1-n) % rows + 1] = entry
            n = n + 1
        end
    end

    window[divider % rows + 1] = 'divider'
    return window
end

function M.draw_rotation(win, start, rows, data, show_entry, draw)
    local window = rotating_window(data, rows, show_entry)
    local last_time
    for i = 1, rows do
        local entry = window[i]
        local y = start + i - 1
        win:wmove(y, 0)
        if entry == 'divider' then
            last_time = os.date '!%H:%M:%S'
            yellow(win)
            win:waddstr(last_time, scroll == 0 and divider_string or scrolled_divider_string)
        elseif entry then
            normal(win)
            local time = entry.time
            if time == last_time then
                win:waddstr '        '
            else
                last_time = time
                M.fade_time(win, entry.timestamp or 0, entry.time)
            end
            normal(win)
            draw(win, entry)
        end
    end
end

local input_mode_palette = {
    command = ncurses.COLOR_BLUE,
    talk = ncurses.COLOR_GREEN,
    filter = ncurses.COLOR_CYAN,
}

function M.draw_status_bar(win)
    local titlecolor = ncurses.COLOR_WHITE

    ncurses.colorset(ncurses.COLOR_BLACK, titlecolor, win)
    win:wmove(0, 0)

    win:waddstr(string.format('%-8.8s', view))

    if input_mode then
        local input_mode_color = input_mode_palette[input_mode]
        ncurses.colorset(titlecolor, input_mode_color, win)
        win:waddstr('')
        ncurses.colorset(ncurses.COLOR_WHITE, input_mode_color, win)
        win:waddstr(input_mode)
        ncurses.colorset(input_mode_color, nil, win)
        win:waddstr('')

        if 1 < editor.first then
            yellow(win)
            win:waddstr('…')
            ncurses.colorset(input_mode_color, nil, win)
        else
            win:waddstr(' ')
        end

        if input_mode == 'filter' then
            if matching.compile(editor:content()) then
                green(win)
            else
                red(win)
            end
        end

        local y0, x0 = ncurses.getyx(win)

        win:waddstr(scrub(editor.before_cursor))

        -- cursor overflow: clear and redraw
        local y1, x1 = ncurses.getyx(win)
        if x1 == tty_width - 1 then
            yellow(win)
            win:wmove(y0, x0-1)
            win:waddstr('…' .. string.rep(' ', tty_width)) -- erase line
            ncurses.colorset(input_mode_color, nil, win)
            editor:overflow()
            win:wmove(y0, x0)
            win:waddstr(scrub(editor.before_cursor))
            y1, x1 = ncurses.getyx(win)
        end

        win:waddstr(scrub(editor.at_cursor))
        win:wmove(y1, x1)
        ncurses.cursset(1)
    else
        ncurses.colorset(titlecolor, nil, win)
        win:waddstr('')
        normal(win)

        views[view]:draw_status(win)

        if status_message then
            addircstr(win, ' ' .. status_message)
        end

        if scroll ~= 0 then
            win:waddstr(string.format(' SCROLL %d', scroll))
        end

        if filter ~= nil then
            yellow(win)
            win:waddstr(' FILTER ')
            normal(win)
            win:waddstr(string.format('%q', filter))
        end

        add_click(tty_height-1, 0, 9, next_view)
        ncurses.cursset(0)
    end
end

return M
