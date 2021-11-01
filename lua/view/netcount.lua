local tablex = require 'pl.tablex'

local M = { title = 'netcount'}

function M:keypress()
end

local function render_entry(y, network, count, nest)
    if nest then
        mvaddstr(y, 0, string.format('%43s┘  ', network))
    else
        bold()
        mvaddstr(y, 0, string.format('%44s  ', network))
        bold_()
    end
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

local function toggle(watch, field, on, off)
    addstr(' ')
    if watch[field] then
        green()
        add_button(on, function()
            watch[field] = nil
        end)
    else
        yellow()
        add_button(off, function()
            watch[field] = true
        end)
    end
end

function M:render()
    green()
    mvaddstr(0,37, "Network  Count  Actions")
    normal()

    local y = 1
    for name, tracker in sortpairs(net_trackers) do
        if y+1 >= tty_height then break end

        cyan()
        render_entry(y, name, tracker:count())

        red()
        add_button('(x)', function()
            net_trackers[name] = nil
        end)

        addstr(' ')
        if tracker.expanded then
            yellow()
            add_button('(-)', function() tracker.expanded = nil end)
            for label, entry in sortpairs(tracker.masks, ordermask) do
                y = y + 1
                if y+1 >= tty_height then break end
                blue()
                render_entry(y, label, entry.count, true)

                red()
                add_button('(x)', function()
                    tracker.masks[label] = nil
                end)
            end
        else
            green()
            add_button('(+)', function() tracker.expanded = true end)
        end
        y = y + 1
    end

    y = y + 1 -- skip a line

    if y+1 < tty_height and next(watches) then
        green()
        mvaddstr(y, 0, "Actions         Watch Hits Mask")
        y = y + 1
    end

    for i, watch in ipairs(watches) do
        if y+1 >= tty_height then break end

        ncurses.move(y,0)

        red()
        add_button('(x)', function()
            table.remove(watches, i)
        end)

        toggle(watch, 'active', '(A)', '(a)')
        toggle(watch, 'beep',   '(B)', '(b)')
        toggle(watch, 'flash',  '(F)', '(f)')

        addstr(string.format(' %3d ', i))
        ncurses.colorset(watch.color or ncurses.red)
        addstr('◆')
        blue()
        addstr(string.format(' %4d', watch.hits))
        normal()
        addstr(string.format(' %-40s', watch.mask))
    end

    draw_global_load('cliconn', conn_tracker)
end

return M
