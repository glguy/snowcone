local M = { title = 'bans' }

local keys = {
    [-ncurses.KEY_PPAGE] = function()
        local elts = math.min(klines.n, klines.max)
        scroll = scroll + math.max(1, tty_height - 3)
        scroll = math.min(scroll, elts - tty_height + 3)
        scroll = math.max(scroll, 0)
    end,
    [-ncurses.KEY_NPAGE] = function()
        scroll = scroll - math.max(1, tty_height - 3)
        scroll = math.max(scroll, 0)
    end,
}

function M:keypress(key)
    local h = keys[key]
    if h then
        h()
        draw()
    end
end

local function pretty_duration(duration)
    local m = math.tointeger(duration)
    if m then
        if m >= 1440 then
            return string.format('%.1f d', m/1440)
        end
        if m >= 60 then
            return string.format('%.1f h', m/60)
        end
        return duration .. 'm'
    else
        return duration
    end
end

local palette = {
    kline = red,
    expired = yellow,
    removed = green,
    inactive = normal,
    kill = magenta,
    dline = cyan,
}

local rotating_window = require_ 'rotating_window'

function M:render()

    local clear_line = string.rep(' ', tty_width)
    local rows = math.max(0, tty_height - 3)
    local window = rotating_window(klines, rows)
    local clear_string = string.rep(' ', tty_width)

    bold()
    magenta()
    addstr('time     operator    duration mask                           affected users and reason')
    bold_()

    for y = 1, rows do
        local entry = window[y]
        if entry == 'divider' then
            yellow()
            mvaddstr(y, 0, os.date('!%H:%M:%S') .. string.rep('·', tty_width-8))
            normal()
        elseif entry then
            mvaddstr(y, 0, clear_string)
            cyan()
            mvaddstr(y, 0, entry.time)

            local oper
            if entry.oper and string.match(entry.oper, '%.') then
                yellow()
                oper = string.match(entry.oper, '^(.-)%.')
            else
                green()
                oper = entry.oper or ''
            end
            addstr(string.format(' %-12.12s ', oper))

            if entry.duration then
                yellow()
                addstr(string.format('%7s ', pretty_duration(entry.duration) or ''))
            else
                normal()
                addstr(string.format('%7.7s ', entry.kind))
            end

            if entry.kind == 'kline' then
                local _, x = ncurses.getyx()
                add_click(y, x, x + #entry.mask, function()
                    snowcone.send_irc('TESTLINE ' .. entry.mask .. '\r\n')
                    staged_action = {action = 'unkline'}
                end)
            elseif entry.kind == 'dline' then
                local _, x = ncurses.getyx()
                add_click(y, x, x + #entry.mask, function()
                    staged_action = {action = 'undline', mask = entry.mask}
                end)
            end

            palette[entry.kind]()
            addstr(string.format('%-30s ', entry.mask))

            local nicks = entry.nicks
            if nicks then
                local xs = {}
                local i = 0
                local n = 0
                for k,v in pairs(nicks) do
                    i = i + 1
                    n = n + v
                    if v > 1 then
                        xs[i] = string.format('%s:%d', k, v)
                    else
                        xs[i] = k
                    end
                    if i == 50 then break end
                end
                if i < 8 then
                    normal()
                    addstr(table.concat(xs, ' ') .. ' ')
                elseif i < 50 then
                    magenta()
                    addstr(string.format('%d nicks %d hits ', i, n))
                else
                    magenta()
                    addstr('many affected ')
                end
            end

            blue()
            addstr(entry.reason or '')

            local y_end = ncurses.getyx()
            for i = y+1,y_end do
                mvaddstr(i, 0, clear_line)
            end
        end
    end
    draw_buttons()
    draw_global_load('cliconn', conn_tracker)
end

return M
