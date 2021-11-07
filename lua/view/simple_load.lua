local drawing = require 'utils.drawing'

return function(title, heading, label, history, tracker)

local M = {
    title = title,
    keypress = function() end,
    draw_status = function() end,
}

function M:render()
    local rows = {}
    for name,load in pairs(tracker.detail) do
        table.insert(rows, {name=name,load=load})
    end
    table.sort(rows, function(x,y)
        return x.name < y.name
    end)

    local y = math.max(tty_height - #rows - 3, 0)

    green()
    mvaddstr(y, 0, string.format('%16s  1m    5m    15m  %s', heading, history))
    normal()
    y = y + 1

    if 3 <= tty_height then
        blue()
        mvaddstr(tty_height-2, 0, string.format('%16s ', label))
        drawing.draw_load(tracker.global)
        normal()
    end

    for _, row in ipairs(rows) do
        if y+2 >= tty_height then return end
        local load = row.load
        local name = row.name
        mvaddstr(y, 0, string.format('%16s ', name))
        drawing.draw_load(load)
        y = y + 1
    end
    draw_global_load('cliconn', conn_tracker)
end

return M
end
