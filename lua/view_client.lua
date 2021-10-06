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
    elseif 0x14 <= key then
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

    local window = {}

    local n = 0
    local rows = math.max(1, tty_height - 1)

    for _, entry in messages:each() do
        local y = (messages_n-1-n) % rows
        window[y] = entry
        n = n + 1
        if n >= rows-1 then break end
    end

    window[messages_n % rows] = 'divider'

    for y = 0, rows - 1 do
        local entry = window[y]
        if entry == 'divider' then
            yellow()
            mvaddstr(y, 0, string.rep('·', tty_width))
            normal()
        else
            mvaddstr(y, 0, render_irc(window[y]))
        end
    end
    cyan()
    mvaddstr(tty_height - 1, 0, buffer)
end

return M
