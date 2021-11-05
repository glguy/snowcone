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
    addstr('nickname         channels (')
    bold_()
    yellow()
    addstr(' * create')
    red()
    addstr(' † flood')
    magenta()
    addstr(' )')

    for y = 1, rows do
        local entry = window[y]
        if entry == 'divider' then
            yellow()
            mvaddstr(y, 0, string.rep('·', tty_width))
            normal()
        elseif entry then
            green()
            mvaddstr(y, 0, string.format('%-16.16s', entry.nick))

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

            local channels = entry.channels
            local flags = entry.flags

            for i = s, n do
                local flag = flags[i]
                cyan()
                addstr(' '..channels[i])

                if flag & 1 == 1 then
                    yellow()
                    addstr('*')
                end

                if flag & 2 == 2 then
                    red()
                    addstr('†')
                end
            end
        end
    end

    draw_global_load('cliconn', conn_tracker)
end

return M
