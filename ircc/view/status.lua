local drawing = require 'utils.drawing'
local addircstr = require 'utils.irc_formatting'

local M = {
    title = 'status',
    draw_status = function() end,
}

local hscroll = 0

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
    [-ncurses.KEY_RIGHT] = function()
        local scroll_unit = math.max(1, tty_width - 26)
        hscroll = math.max(0, math.min(1024 - scroll_unit, hscroll + scroll_unit))
    end,
    [-ncurses.KEY_LEFT] = function()
        local scroll_unit = math.max(1, tty_width - 26)
        hscroll = math.max(0, hscroll - scroll_unit)
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

function M:render()
    magenta()
    bold()
    addstr('time     category   message')
    bold_()

    local rows = math.max(0, tty_height - 2)
    drawing.draw_rotation(1, rows, status_messages, show_entry, function(entry)
        blue()
        addstr(string.format(' %-10.10s ', entry.category or '-'))
        normal()
        addircstr(entry.text:sub(hscroll))
    end)
end

return M
