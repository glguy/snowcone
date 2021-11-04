local rotating_window = require 'utils.rotating_window'

local M = {
    title = "channels",
    keypress = function() end,
    draw_status = function() end,
}

function M:render()
    local rows = math.max(1, tty_height - 2)
    local window = rotating_window(new_channels, rows)

    magenta()
    bold()
    addstr('nickname                 channels')
    bold_()

    for y = 1, rows do
        local entry = window[y]
        if entry == 'divider' then
            yellow()
            mvaddstr(y, 0, string.rep('·', tty_width))
            normal()
        elseif entry then
            green()
            mvaddstr(y, 0, string.format('%-24.24s ', entry.nick))

            local n = #entry.channels
            local limit = 4
            local s = math.max(1, n-limit+1)
            if n > limit then
                red()
                bold()
                addstr('+'..(n-limit) .. ' ')
                bold_()
            end
            cyan()

            addstr(table.concat(entry.channels, ' ', s))
        end
    end

    draw_global_load('cliconn', conn_tracker)
end

return M
