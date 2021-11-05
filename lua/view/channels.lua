local rotating_window = require 'utils.rotating_window'

local M = {
    title = "channels",
    keypress = function() end,
    draw_status = function() end,
}


local function safematch(str, pat)
    local success, result = pcall(string.match, str, pat)
    return not success or result
end

local function match_any(t, pat)
    if t then
        for _, v in ipairs(t) do
            if safematch(v, pat) then
                return true
            end
        end
    end
end

local function show_entry(entry)
    local current_filter
    if input_mode == 'filter' then
        current_filter = editor.rendered
    else
        current_filter = filter
    end

    return
        (current_filter == nil or
        safematch(entry.nick, current_filter) or
        match_any(entry.channels, current_filter)
        )
end

function M:render()
    local rows = math.max(1, tty_height - 2)
    local window = rotating_window(new_channels, rows, show_entry)

    magenta()
    bold()
    addstr('nickname         channels (')
    yellow()
    addstr(' * create')
    red()
    addstr(' † flood')
    magenta()
    addstr(' )')
    bold_()

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
            local limit = 5
            local s = math.max(1, n-limit+1)
            if n > limit then
                red()
                bold()
                addstr(' +'..(n-limit))
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
