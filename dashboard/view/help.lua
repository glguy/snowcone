local tablex = require 'pl.tablex'

local M = {
    title = 'help',
    keypress = function() end,
    draw_status = function() end,
}

function M:render()
    magenta()
    bold()
    addstr 'Commands\n'
    normal()

    local entries = {}
    local width = 1

    for k,v in tablex.sort(commands) do
        local text = '/' .. k .. ' ' .. v.spec
        local n = #text
        if n > width then width = n end
        table.insert(entries, text)
    end

    local y = 1
    local x = 0

    for k,v in tablex.sort(commands) do
        mvaddstr(y, x, '/' .. k .. ' ' .. v.spec)

        if tty_height <= y+2 then
            y = 1
            x = x + width + 1
        else
            y = y + 1
        end
    end

    draw_global_load('cliconn', conn_tracker)
end

return M
