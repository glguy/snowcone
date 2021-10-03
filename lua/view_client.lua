local pretty = require 'pl.pretty'

local function render_irc(irc)
    local parts = {}

    if irc.source then
        table.insert(parts, ':'..irc.source)
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

    local full = table.concat(parts, ' ')
    if #full > tty_width then
        full = string.sub(full, 1, tty_width) -- better to do something with unicode!
    end
    return string.gsub(full, '%c', '.')
end

local M = {}

local buffer = ""

function M:keypress(key)
    if key == 0x1b then
        buffer = ''
    elseif key == 0x7f then
        buffer = string.sub(buffer, 1, #buffer - 1)
    elseif 0x14 <= key and key < 0x7f then
        buffer = buffer .. utf8.char(key)
    elseif key == 0xd then
        send_irc(buffer..'\r\n')
        buffer = ''
    else
        buffer = string.format('%s[%d]', buffer, key)
    end
    draw()
end

function M:render()

    local y = tty_height - 1
    
    mvaddstr(y, 0, buffer)
    y = y - 1

    for _, irc in messages:each() do
        ncurses.mvaddstr(y, 0, render_irc(irc))

        y = y - 1
        if y < 0 then
            break
        end
    end
end

return M
