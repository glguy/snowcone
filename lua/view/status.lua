local drawing = require 'utils.drawing'
local addircstr = require 'utils.irc_formatting'

local M = {
    title = 'status',
    draw_status = function() end,
}

local keys = {
    [-ncurses.KEY_PPAGE] = function()
        local elts = math.min(status_messages.n, status_messages.max)
        scroll = scroll + math.max(1, tty_height - 3)
        scroll = math.min(scroll, elts - tty_height + 3)
        scroll = math.max(scroll, 0)
    end,
    [-ncurses.KEY_NPAGE] = function()
        scroll = scroll - math.max(1, tty_height - 3)
        scroll = math.max(scroll, 0)
    end,
}

function M:keypress(key)
    local h = keys[key]
    if h then
        h()
        draw()
    end
end

local function safematch(str, pat)
    local success, result = pcall(string.match, str, pat)
    return not success or result
end

local function show_entry(entry)
    local current_filter
    if input_mode == 'filter' then
        current_filter = editor.rendered
    else
        current_filter = filter
    end

    return safematch(entry.text, current_filter)
end

function M:render()
    local rows = math.max(0, tty_height - 1)
    drawing.draw_rotation(0, rows, status_messages, show_entry, function(entry)
        blue()
        addstr(string.format(' %-10.10s ', entry.category or '-'))
        normal()
        addircstr(entry.text)
    end)
    draw_global_load('cliconn', conn_tracker)
end

return M
