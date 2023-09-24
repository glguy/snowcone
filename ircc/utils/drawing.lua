local irc_formatting = require 'utils.irc_formatting'
local matching = require 'utils.matching'
local M = {}

function M.fade_time(timestamp, time)
    local age = uptime - timestamp
    if age < 8 then
        white()
        addstr(string.sub(time, 1, 8-age))
        cyan()
        addstr(string.sub(time, 9-age, 8))
    else
        cyan()
        addstr(time)
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

function M.draw_rotation(start, rows, data, show_entry, draw)
    local window = rotating_window(data, rows, show_entry)
    local clear_string = string.rep(' ', tty_width)

    local last_time
    for i = 1, rows do
        local entry = window[i]
        local y = start + i - 1
        if entry == 'divider' then
            last_time = os.date '!%H:%M:%S'
            yellow()
            mvaddstr(y, 0, last_time, string.rep('·', tty_width-8))
            normal()
        elseif entry then
            normal()
            mvaddstr(y, 0, clear_string)
            ncurses.move(y, 0)
            local time = entry.time
            if time == last_time then
                addstr '        '
            else
                last_time = time
                M.fade_time(entry.timestamp or 0, entry.time)
            end
            normal()
            draw(entry)
        else
            normal()
            mvaddstr(y, 0, clear_string)
        end
    end
end

local input_mode_palette = {
    command = ncurses.blue,
    talk = ncurses.green,
    filter = ncurses.cyan,
}

function M.draw_status_bar()
    local titlecolor = ncurses.white

    ncurses.colorset(ncurses.black, titlecolor)
    mvaddstr(tty_height-1, 0, string.format('%-8.8s', view))

    if input_mode then
        local input_mode_color = input_mode_palette[input_mode]
        ncurses.colorset(titlecolor, input_mode_color)
        addstr('')
        ncurses.colorset(ncurses.white, input_mode_color)
        addstr(input_mode)
        ncurses.colorset(input_mode_color)
        addstr('')

        if 1 < editor.first then
            yellow()
            addstr('…')
            ncurses.colorset(input_mode_color)
        else
            addstr(' ')
        end

        if input_mode == 'filter' then
            if matching.compile(editor:content()) then
                green()
            else
                red()
            end
        end

        local y0, x0 = ncurses.getyx()

        addstr(editor.before_cursor)

        -- cursor overflow: clear and redraw
        local y1, x1 = ncurses.getyx()
        if x1 == tty_width - 1 then
            yellow()
            mvaddstr(y0, x0-1, '…' .. string.rep(' ', tty_width)) -- erase line
            ncurses.colorset(input_mode_color)
            editor:overflow()
            mvaddstr(y0, x0, editor.before_cursor)
            y1, x1 = ncurses.getyx()
        end

        addstr(editor.at_cursor)
        ncurses.move(y1, x1)
        ncurses.cursset(1)
    else
        ncurses.colorset(titlecolor)
        addstr('')
        normal()

        views[view]:draw_status()

        if status_message then
            irc_formatting(' ' .. status_message)
        end

        if scroll ~= 0 then
            addstr(string.format(' SCROLL %d', scroll))
        end

        if filter ~= nil then
            yellow()
            addstr(' FILTER ')
            normal()
            addstr(string.format('%q', filter))
        end

        add_click(tty_height-1, 0, 9, next_view)
        ncurses.cursset(0)
    end
end

return M
