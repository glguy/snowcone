local pretty = require 'pl.pretty'

local function render_irc(irc)
    local parts = {}

    if irc.source then
        table.insert(parts, source)
    end

    table.insert(parts, irc.command)

    local n = #irc
    for i,arg in ipairs(irc) do
        if i == n then
            table.insert(parts, ':'..arg)
        else
            table.insert(parts, arg)
        end
    end

    return table.concat(parts, ' ')
end

local M = {}

function M:keypress()
end

function M:render()

    local y = tty_height - 2
    
    for _, irc in messages:each() do
        ncurses.mvaddstr(y, 0, render_irc(irc))

        y = y - 1
        if y < 0 then
            break
        end
    end
end

return M
