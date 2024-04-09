local tablex = require 'pl.tablex'

local M = {
    title = 'help',
    keypress = function() end,
    draw_status = function() end,
}

function M:render(win)
    magenta(win)
    bold(win)
    win:waddstr 'Commands\n'
    normal(win)

    local entries = {}
    local width = 1

    local function do_command(k,v)
        local text = '/' .. k .. ' ' .. v.spec
        local n = #text
        if n > width then width = n end
        entries[k] = text
    end

    for k,v in pairs(commands) do
        do_command(k,v)
    end

    for _, plugin in pairs(plugins) do
        for k,v in pairs(plugin.commands) do
            do_command(k,v)
        end
    end

    local y = 1
    local x = 0

    for _, str in tablex.sort(entries) do
        ncurses.move(y, x, win)
        win:waddstr(str)

        if tty_height <= y+2 then
            y = 1
            x = x + width + 1
        else
            y = y + 1
        end
    end
end

return M
