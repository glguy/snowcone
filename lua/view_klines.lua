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
}

function M:render()

    local window = {}
    local clear_string = string.rep(' ', tty_width)

    local n = 0
    local rows = math.max(1, tty_height - 1)

    for _, entry in klines:each() do
        local y = (klines.n-1-n) % rows + 1
        window[y] = entry
        n = n + 1
        if n >= rows-1 then break end
    end

    window[klines.n % rows + 1] = 'divider'

    bold()
    magenta()
    addstr('time     kind     operator   duration mask                                     reason')
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
            normal()
            addstr(string.format(' %-8s ', entry.kind or 'xx'))
            green()
            addstr(string.format('%-12s ', entry.oper or ''))
            yellow()
            addstr(string.format('%6s ', pretty_duration(entry.duration) or ''))
            palette[entry.kind]()
            addstr(string.format('%-40s ', entry.mask))
            blue()
            addstr(entry.reason or '')
        end
    end
    draw_global_load('CLICON', conn_tracker)
end

return M
