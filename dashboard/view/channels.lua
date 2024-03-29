local drawing = require_ 'utils.drawing'

local M = {
    title = "channels",
    keypress = function() end,
    draw_status = function() end,
}

local matching = require 'utils.matching'
local safematch = matching.safematch

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
    local current_filter = matching.current_pattern()
    return
        (current_filter == nil or
        safematch(entry.nick, current_filter) or
        match_any(entry.channels, current_filter)
        )
end

function M:render()
    local rows = math.max(1, tty_height - 2)

    magenta()
    bold()
    addstr('time     nickname         channels (')
    yellow()
    addstr(' * create')
    red()
    addstr(' † flood')
    white()
    addstr(' ◆ spambot')
    magenta()
    addstr(' )')
    bold_()

    drawing.draw_rotation(1, rows, new_channels, show_entry, function(entry)
        green()
        addstr(string.format(' %-16.16s', entry.nick))

        local channels = entry.channels
        local flags = entry.flags

        local n = #channels
        local limit = 5
        local s = math.max(0, n-limit)

        if n > limit then
            local creates, floods, spambot = 0, 0, 0
            for i = 1, s do
                if flags[i] & 1 == 1 then creates = creates + 1 end
                if flags[i] & 2 == 2 then floods = floods + 1 end
                if flags[i] & 4 == 4 then spambot = spambot + 1 end
            end

            if creates > 0 then
                yellow() addstr(' ' .. creates .. '*')
            end

            if floods > 0 then
                red() addstr(' ' .. floods .. '†')
            end

            if spambot > 0 then
                white() addstr(' ' .. spambot .. '◆')
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

            if flag & 4 == 4 then
                white()
                addstr('◆')
            end
        end
    end)

    draw_global_load('cliconn', conn_tracker)
end

return M
