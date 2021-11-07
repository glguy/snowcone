local rotating_window = require 'utils.rotating_window'
local drawing = require_ 'utils.drawing'

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
    addstr('time     nickname         channels (')
    yellow()
    addstr(' * create')
    red()
    addstr(' † flood')
    magenta()
    addstr(' )')
    bold_()

    local last_time
    for y = 1, rows do
        ncurses.move(y, 0)
        local entry = window[y]

        if entry == 'divider' then
            yellow()
            addstr(os.date '!%H:%M:%S' .. string.rep('·', tty_width - 8))
            normal()

        elseif entry then
            local time = entry.time
            if time == last_time then
                addstr('        ')
            else
                last_time = time
                drawing.fade_time(entry.timestamp, time)
            end

            green()
            addstr(string.format(' %-16.16s', entry.nick))

            local channels = entry.channels
            local flags = entry.flags

            local n = #channels
            local limit = 5
            local s = math.max(0, n-limit)

            if n > limit then
                local creates, floods = 0, 0
                for i = 1, s do
                    if flags[i] & 1 == 1 then creates = creates + 1 end
                    if flags[i] & 2 == 2 then floods = floods + 1 end
                end

                if creates > 0 then
                    yellow() addstr(' ' .. creates .. '*')
                end

                if floods > 0 then
                    red() addstr(' ' .. floods .. '†')
                end
            end
            cyan()

            for i = s+1, n do
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
