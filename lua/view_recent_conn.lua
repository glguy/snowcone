local M = {}

local handlers = {
    [-ncurses.KEY_PPAGE] = function()
        scroll = scroll + math.max(1, tty_height - 2)
        scroll = math.min(scroll, users.n - 1)
        scroll = math.max(scroll, 0)
    end,
    [-ncurses.KEY_NPAGE] = function()
        scroll = scroll - math.max(1, tty_height - 2)
        scroll = math.max(scroll, 0)
    end,
    --[[ESC]][0x1b] = function() reset_filter() status_message = '' end,
    [string.byte('q')] = function() conn_filter = true  end,
    [string.byte('w')] = function() conn_filter = false end,
    [string.byte('e')] = function() conn_filter = nil   end,
    [string.byte('k')] = function()
        if staged_action.action == 'kline' then
            send_irc(
                string.format('KLINE %s %s :%s\r\n',
                    kline_durations[kline_duration][2],
                    staged_action.mask,
                    kline_reasons[kline_reason][2]
                )
            )
            staged_action = nil
        end
    end,
}

function M:keypress(key)
    local f = handlers[key]
    if f then
        f()
        draw()
    end
end

function M:render()
    local skips = scroll or 0
    local last_time
    local n = 0
    local rotating_view = scroll == 0 and conn_filter == nil

    local rows = math.max(1, tty_height-2)

    local window = {}
    for _, entry in users:each() do
        if show_entry(entry) then
            local y
            if rotating_view then
                y = (clicon_n-1-n) % rows
            else
                y = rows-1-n
            end

            if skips == 0 then
                window[y] = entry
                n = n + 1
                if rotating_view then
                    if n >= rows-1 then break end
                else
                    if n >= rows then break end
                end
            else
                skips = skips - 1
            end
        end
    end

    if rotating_view then
        window[clicon_n % rows] = 'divider'
    end

    for y = 0,rows-1 do
        local entry = window[y]
        if entry == 'divider' then
            yellow()
            mvaddstr(y, 0, string.rep('·', tty_width))
            normal()
            last_time = nil
        elseif entry then
            -- TIME
            local time = entry.time
            local timetxt
            if time == last_time then
                mvaddstr(y, 0, '        ')
            else
                last_time = time

                local age = uptime - (entry.timestamp or 0)
                if age < 8 then
                    white()
                    mvaddstr(y, 0, string.sub(time, 1, 8-age))
                    cyan()
                    addstr(string.sub(time, 9-age, 8))
                else
                    cyan()
                    mvaddstr(y, 0, time)
                end
                normal()
            end

            local mask_color = entry.connected and ncurses.green or ncurses.red

            if entry.filters then
                ncurses.attron(mask_color)
                addstr(string.format(' %3d! ', entry.filters))
            else
                if entry.count < 2 then
                    black()
                end
                addstr(string.format(" %4d ", entry.count))
            end
            -- MASK
            if highlight and (
                highlight_plain     and highlight == entry.mask or
                not highlight_plain and string.match(entry.mask, highlight)) then
                    bold()
            end

            ncurses.attron(mask_color)
            addstr(entry.nick)
            black()
            addstr('!')
            ncurses.attron(mask_color)
            addstr(entry.user)
            black()
            addstr('@')
            ncurses.attron(mask_color)
            local maxwidth = 63 - #entry.nick - #entry.user
            if #entry.host <= maxwidth then
                addstr(entry.host)
                normal()
            else
                addstr(string.sub(entry.host, 1, maxwidth-1))
                normal()
                addstr('…')
            end

            -- IP or REASON
            if show_reasons and not entry.connected then
                if entry.reason == 'K-Lined' then
                    red()
                else
                    magenta()
                end
                mvaddstr(y, 80, string.sub(entry.reason, 1, 39))
            elseif entry.org then
                if entry.connected then
                    yellow()
                elseif entry.reason == 'K-Lined' then
                    red()
                else
                    magenta()
                end
                mvaddstr(y, 80, string.sub(entry.org, 1, 39))
            else
                yellow()
                mvaddstr(y, 80, entry.ip)
            end

            blue()
            local server = (servers[entry.server] or {}).alias
                        or string.substr(entry.server, 1, 2)
            mvaddstr(y, 120, server)

            -- GECOS or account
            normal()
            local account = entry.account
            if account == '*' then
                mvaddstr(y, 123, entry.gecos)
            else
                cyan()
                mvaddstr(y, 123, account)
		        normal()
            end

            -- Click handlers
            if entry.reason == 'K-Lined' then
                add_click(y, 0, tty_width, function()
                    entry_to_unkline(entry)
                    highlight = entry.mask
                    highlight_plain = true
                end)
            else
                add_click(y, 0, tty_width, function()
                    entry_to_kline(entry)
                    highlight = entry.mask
                    highlight_plain = true
                end)
            end
        end
    end

    draw_buttons()

    draw_global_load('CLICON', conn_tracker)

    if scroll ~= 0 then
        addstr(string.format(' scroll %d', scroll))
    end
    if filter ~= nil then
        yellow()
        addstr(' FILTER ')
        normal()
        addstr(string.format('%q', filter))
    end
    if conn_filter ~= nil then
        if conn_filter then
            green() addstr(' LIVE')
        else
            red() addstr(' DEAD')
        end
        normal()
    end
end

return M
