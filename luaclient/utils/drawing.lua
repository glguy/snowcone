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
            mvaddstr(y, 0, last_time .. string.rep('·', tty_width-8))
            normal()
        elseif entry then
            normal()
            mvaddstr(y, 0, clear_string)
            ncurses.move(y, 0)
            local time = entry.time
            if time == last_time then
                addstr('        ')
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

return M
