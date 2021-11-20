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

function M.add_population(pop)
    if pop then
        if pop < 1000 then
            addstr(string.format('%5d', pop))
        else
            bold()
            addstr(string.format('%2d', pop // 1000))
            bold_()
            addstr(string.format('%03d', pop % 1000))
        end
    else
        addstr('    ?')
    end
end

local function draw_load_1(avg, i)
    if avg.n >= 60*i then
        bold()
        addstr(string.format('%5.2f ', avg[i]))
        bold_()
    else
        addstr(string.format('%5.2f ', avg[i]))
    end
end

function M.draw_load(avg)
    draw_load_1(avg, 1)
    draw_load_1(avg, 5)
    draw_load_1(avg,15)
    addstr('[')
    underline()
    addstr(avg:graph())
    underline_()
    addstr(']')
end

local function rotating_window(source, rows, predicate)
    source.predicate = predicate
    if rows <= 0 then return {} end

    local n = 0
    local window = {}

    for entry in source:each(scroll) do
        if n+1 >= rows then break end -- saves a row for divider
        if not predicate or predicate(entry) then
            window[(source.ticker-1-n) % rows + 1] = entry
            n = n + 1
        end
    end

    window[source.ticker % rows + 1] = 'divider'
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