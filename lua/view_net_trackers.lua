local M = {}

function M:keypress()
end

local function render_entry(y, network, count)
    mvaddstr(y, 0, string.format('%40s  ', network))
    if count > 999 then
        bold()
        addstr(string.format('%2d', count//1000))
        bold_()
        addstr(string.format('%03d  ', count%1000))
    else
        addstr(string.format('%5d  ', count))
    end
end

local function sortpairs(t, f)
    local keys = tablex.keys(t)
    if f then
        table.sort(keys, function(x,y) return f(t[x], t[y]) end)
    else
        table.sort(keys)
    end
    local i = 0
    return function()
        i = i + 1
        local k = keys[i]
        if k then
            return k, t[k]
        end
    end
end

local function ordermask(v1, v2)
    return v1.addrlen < v2.addrlen
        or v1.addrlen == v2.addrlen
       and (v1.network < v2.network
        or v1.network == v2.network and v1.tailbyte < v2.tailbyte)
end

function M:render()
    cyan()
    mvaddstr(0,33, "Network  Count  Actions")
    normal()

    local y = 1
    for name, tracker in sortpairs(net_trackers) do
        if y+1 >= tty_height then break end

        normal()
        render_entry(y, name, tracker:count())

        red()
        add_button('[X]', function()
            net_trackers[name] = nil
        end)

        addstr(' ')
        if tracker.expanded then
            yellow()
            add_button('[-]', function() tracker.expanded = nil end)
            blue()
            for label, entry in sortpairs(tracker.masks, ordermask) do
                y = y + 1
                if y+1 >= tty_height then break end
                render_entry(y, label, entry.count)
            end
        else
            green()
            add_button('[+]', function() tracker.expanded = true end)
        end
        y = y + 1
    end

    draw_global_load('CLICON', conn_tracker)
end

return M
