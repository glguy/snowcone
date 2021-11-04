local pretty = require 'pl.pretty'

local M = {
    title = 'stats',
    keypress = function() end,
    draw_status = function() end,
}

local function list_stats(name, data)
    addstr(string.format('%10s %10d %10d', name, data.n, data.max))
end


function M:render()
    green()
    mvaddstr(0, 0,'          -= stats =-')
    normal()

    mvaddstr(2, 0, "collectgarbage 'count': ")
    bold()
    addstr(string.format('%10s ', pretty.number(collectgarbage 'count' * 1024, 'M')))
    bold_()
    add_button('[GC]', function() collectgarbage() end)

    green()
    mvaddstr(4, 0,'   dataset         .n       .max')
    normal()

    ncurses.move(5, 0)
    list_stats('users', users)

    ncurses.move(6, 0)
    list_stats('exits', exits)

    ncurses.move(7, 0)
    list_stats('klines', klines)

    ncurses.move(8, 0)
    list_stats('messages', messages)

    mvaddstr(10, 0, string.format('uptime: %8d    msg-idle: %8d', uptime, uptime - liveness))

    draw_global_load('cliconn', conn_tracker)
end

return M
