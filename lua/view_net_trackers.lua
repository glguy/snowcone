local M = {}

function M:keypress()
end

function M:render()
    cyan()
    mvaddstr(0,0, "Network trackers")
    normal()

    for i, tracker in ipairs(net_trackers) do
        mvaddstr(i, 0, string.format('%40s %5d', tracker.label, tracker.count))
        if i+1 >= tty_height then break end
    end

    draw_global_load('CLICON', conn_tracker)
end

return M
