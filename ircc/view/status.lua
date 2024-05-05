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
    [-ncurses.KEY_UP] = function()
        local elts = math.min(status_messages.n, status_messages.max)
        scroll = math.min(scroll + 1, elts - tty_height + 3)
        scroll = math.max(scroll, 0)
    end,
    [-ncurses.KEY_DOWN] = function()
        scroll = math.max(scroll - 1, 0)
    end,
}

function M:keypress(key)
    local h = keys[key]
    if h then
        h()
        return true -- consume
    end
end

local matching = require 'utils.matching'
local function show_entry(entry)
    local current_filter = matching.current_pattern()
    return matching.safematch(entry.text, current_filter)
end

local function draw_entry(win, entry)
    blue(win)
    win:waddstr(string.format(' %-10.10s ', entry.category or '-'))
    normal(win)
    addircstr(win, entry.text)
end

function M:render(win)
    magenta(win)
    bold(win)
    win:waddstr('time     category   message')
    bold_(win)

    local rows = math.max(0, tty_height - 2)
    drawing.draw_rotation(win, 1, rows, status_messages, show_entry, draw_entry)
end

return M
