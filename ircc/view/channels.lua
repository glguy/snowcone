local drawing = require 'utils.drawing'
local scrub = require 'utils.scrub'
local addircstr = require 'utils.irc_formatting'
local send = require 'utils.send'

local M = {
    title = 'list',
    draw_status = function() end,
}

local keys = {
    [-ncurses.KEY_PPAGE] = function()
        local elts = math.min(channel_list.n, channel_list.max)
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
        return true -- consume
    end
end

local matching = require 'utils.matching'
local function show_entry(entry)
    local current_filter = matching.current_pattern()
    return matching.safematch(entry.channel, current_filter)
        or matching.safematch(entry.users, current_filter)
        or matching.safematch(entry.topic, current_filter)
end

local function draw_entry(win, entry)
    green(win)
    win:waddstr(' ', scrub(entry.channel))
    blue(win)
    win:waddstr(' ', entry.users, ' ')
    normal(win)
    addircstr(win, entry.topic)
end

function M:render(win)
    magenta(win)
    bold(win)
    win:waddstr('         channels: ', channel_list.n, ' ')
    add_button(win, '[REFRESH]', function()
        require('utils.channel_list')()
    end)
    bold_(win)

    local rows = math.max(0, tty_height - 2)
    drawing.draw_rotation(win, 1, rows, channel_list, show_entry, draw_entry)
end

return M
