local M = {}

function M:keypress()
end

local function fmt(n)
    return string.gsub(string.format('%.2f', n), '%.?0*$', '')
end

local function pretty_duration(duration)
    local m = math.tointeger(duration)
    if m then
        if m >= 1440 then
            return fmt(m/1440) .. 'd'
        end
        if m >= 60 then
            return fmt(m/60) .. 'h'
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
}

local rotating_window = require 'rotating_window'

function M:render()

    local clear_line = string.rep(' ', tty_width)
    local rows = math.max(0, tty_height - 2)
    local window = rotating_window.build_window(klines, 'each', rows)
    local clear_string = string.rep(' ', tty_width)

    bold()
    magenta()
    addstr('time     operator   duration mask                           affected users and reason')
    bold_()

    for y = 1, rows - 1 do
        local entry = window[y]
        if not entry then
            break
        elseif entry == 'divider' then
            yellow()
            mvaddstr(y, 0, os.date('!%H:%M:%S') .. string.rep('·', tty_width-8))
            normal()
        else
            mvaddstr(y, 0, clear_string)
            cyan()
            mvaddstr(y, 0, entry.time)
            green()
            addstr(string.format(' %-12s ', entry.oper or ''))
            if entry.duration then
                yellow()
                addstr(string.format('%6s ', pretty_duration(entry.duration) or ''))
            else
                normal()
                addstr(string.format('%6.6s ', entry.kind))
            end

            if entry.kind == 'kline' then
                local _, x = ncurses.getyx()
                add_click(y, x, x + #entry.mask, function()
                    snowcone.send_irc('TESTLINE ' .. entry.mask .. '\r\n')
                    staged_action = {action = 'unkline', entry = {nick = '*'}}
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
    draw_global_load('CLICON', conn_tracker)
end

return M
