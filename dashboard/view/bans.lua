local scrub = require 'utils.scrub'
local drawing = require 'utils.drawing'
local time = require 'utils.time'
local send = require 'utils.send'

local M = {
    title = 'bans',
    draw_status = function() end,
}

local keys = {
    [-ncurses.KEY_PPAGE] = function()
        local elts = math.min(klines.n, klines.max)
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

local palette = {
    kline = red,
    expired = yellow,
    removed = green,
    inactive = normal,
    kill = magenta,
    dline = cyan,
}

local utils_filter = require 'utils.filter'
local safematch = utils_filter.safematch

local function match_key(t, pat)
    if t then
        for k, _ in pairs(t) do
            if safematch(k, pat) then
                return true
            end
        end
    end
end

local function show_entry(entry)
    local current_filter = utils_filter.current_pattern()
    return
    (server_filter == nil or server_filter == entry.server) and
    (conn_filter == nil or conn_filter == not entry.reason) and
    (current_filter == nil or
     safematch(entry.mask, current_filter) or
     safematch(entry.reason, current_filter) or
     match_key(entry.nicks, current_filter))
end

function M:render()
    bold()
    magenta()
    addstr('time     operator    duration mask                           affected users and reason')
    bold_()

    local rows = math.max(0, tty_height - 3)
    drawing.draw_rotation(1, rows, klines, show_entry, function(entry)
        local oper
        if entry.oper and string.match(entry.oper, '%.') then
            yellow()
            oper = string.match(entry.oper, '^(.-)%.')
        else
            green()
            oper = entry.oper or ''
        end
        addstr(string.format(' %-12.12s ', oper))

        if entry.duration then
            yellow()
            addstr(string.format('%7s ', time.pretty_duration(entry.duration) or ''))
        else
            normal()
            addstr(string.format('%7.7s ', entry.kind))
        end

        if entry.kind == 'kline' then
            local y, x = ncurses.getyx()
            add_click(y, x, x + #entry.mask, function()
                send('TESTLINE', entry.mask)
                staged_action = {action = 'unkline'}
            end)
        elseif entry.kind == 'dline' then
            local y, x = ncurses.getyx()
            add_click(y, x, x + #entry.mask, function()
                staged_action = {action = 'undline', mask = entry.mask}
            end)
        end

        palette[entry.kind]()
        addstr(string.format('%-30s ', entry.mask))

        local nicks = entry.nicks
        if nicks then
            local xs = {}
            local i = 0
            local n = 0
            for k,v in pairs(nicks) do
                i = i + 1
                n = n + v
                if v > 1 then
                    xs[i] = string.format('%s:%d', k, v)
                else
                    xs[i] = k
                end
                if i == 50 then break end
            end
            if i < 8 then
                normal()
                addstr(table.concat(xs, ' ') .. ' ')
            elseif i < 50 then
                magenta()
                addstr(string.format('%d nicks %d hits ', i, n))
            else
                magenta()
                addstr('many affected ')
            end
        end

        blue()
        if entry.reason then
            addstr(scrub(entry.reason))
        end
    end)

    draw_buttons()
    draw_global_load('cliconn', conn_tracker)
end

return M
