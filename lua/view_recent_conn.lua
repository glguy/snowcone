return function()
    local skips = scroll or 0
    local last_time
    local n = 0
    local rotating_view = scroll == 0 and conn_filter == nil

    local rows = math.max(1, tty_height-2)

    for _, entry in users:each() do
        if show_entry(entry) then
            local y
            if rotating_view then
                if n >= rows-1 then break end
                y = (clicon_n-n) % rows
            else
                if n >= rows then break end
                y = rows-n-1
            end

            if skips > 0 then skips = skips - 1 goto skip end

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
                attron(mask_color)
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

            attron(mask_color)
            addstr(entry.nick)
            black()
            addstr('!')
            attron(mask_color)
            addstr(entry.user)
            black()
            addstr('@')
            attron(mask_color)
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
            local server = elements[string.match(entry.server, '[^.]*')]
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

            n = n + 1

            ::skip::
        end
    end

    if rotating_view then
        local y = (clicon_n+1) % rows
        yellow()
        mvaddstr(y, 0, string.rep('·', tty_width))
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
    if last_key ~= nil then
        addstr(' key ' .. tostring(last_key))
    end
end
