local addircstr = require_ 'utils.irc_formatting'
local parse_snote = require 'utils.parse_snote'
local drawing = require 'utils.drawing'
local numerics = require 'utils.numerics'
local scrub = require 'utils.scrub'
local tablex = require 'pl.tablex'
local hide_snow = false
local show_raw = false

local palette = {
    PRIVMSG = blue,
    NOTICE = cyan,
    JOIN = green,
    PART = yellow,
    QUIT = magenta,
}

-- Compute the pretty names for IRC numerics for use in focused view
local numeric_names = {}
for name, numeric in pairs(numerics) do
    numeric_names[numeric] = name
    if name:startswith 'ERR_' then
        palette[numeric] = red
    end
end

local function pretty_source(win, source)
    if source == '>>>' then
        red(win)
    else
        local head, kind = string.match(source, '^(.-)([.!])')
        source = head or source
        if kind == '!' then
            cyan(win)
        else
            yellow(win)
        end
    end
    win:waddstr(string.format('%16.16s ', scrub(source)))
    normal(win)
end

-- Predicate for server notices
-- Return the body of the notice with the header removed
local function match_snotice(irc)
    if irc.source and irc.command == 'NOTICE'
    and irc[1] == '*' and #irc == 2
    and irc[2]:startswith '*** Notice -- ' then
        return string.sub(irc[2], 15)
    end
end

local function set_focus(irc)
    focus = { irc = irc }
    local snote_text = match_snotice(irc)
    if snote_text ~= nil then
        focus.snotice = parse_snote(nil, irc.source, snote_text)
    end
end

local function render_irc(win, irc)
    local snote_text = match_snotice(irc)
    if snote_text ~= nil then
        pretty_source(win, irc.source)
        magenta(win)
        bold(win)
        add_button(win, 'SNOW ', function() set_focus(irc) end, true)
        bold_(win)
        cyan(win)
        win:waddstr ':'
        normal(win)
        addircstr(win, snote_text)
        return
    end

    if irc.source then
        pretty_source(win, irc.source)
    else
        win:waddstr(string.rep(' ', 17))
    end

    local color = palette[irc.command]
    if color then color(win) end
    bold(win)
    add_button(win, string.format('%4.4s', irc.command), function() set_focus(irc) end, true)
    normal(win)

    local n = #irc
    for i,arg in ipairs(irc) do
        if i == n and (arg == '' or arg:startswith ':' or arg:match ' ') then
            cyan(win)
            win:waddstr ' :'
            normal(win)
            addircstr(win, arg)
        else
            addircstr(win, ' '..arg)
        end
    end
end

local M = {
    active = true,
    title = 'console',
}

local keys = {
    [-ncurses.KEY_PPAGE] = function()
        local elts = math.min(messages.max, messages.n)
        scroll = scroll + math.max(1, tty_height - 2)
        scroll = math.min(scroll, elts - tty_height + 2)
        scroll = math.max(scroll, 0)
    end,
    [-ncurses.KEY_NPAGE] = function()
        scroll = scroll - math.max(1, tty_height - 1)
        scroll = math.max(scroll, 0)
    end,
    [-ncurses.KEY_RIGHT] = function()
        local scroll_unit = math.max(1, tty_width - 26)
        hscroll = math.max(0, math.min(550 - scroll_unit, hscroll + scroll_unit))
    end,
    [-ncurses.KEY_LEFT] = function()
        local scroll_unit = math.max(1, tty_width - 26)
        hscroll = math.max(0, hscroll - scroll_unit)
    end,
    [meta 'h'] = function() hide_snow = not hide_snow end,
    [meta 'r'] = function() show_raw = not show_raw end,
}

function M:keypress(key)
    local h = keys[key]
    if h then
        h()
        return true -- consume
    end
end

local escapes = {
    ['"'] = '\\"',
    ['\\'] = '\\\\',
    ['\a'] = '\\a',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
    ['\v'] = '\\v',
}

local function rawstr(str)
    str = string.gsub(str, '[\x00-\x1f"\\\x7f-\xff]', function(c)
        return escapes[c] or string.format('\\x%02x', string.byte(c))
    end)
    return '"' .. str .. '"'
end

local function draw_focus(win, irc, snotice)
    --
    -- MESSAGE TAGS
    --
    if next(irc.tags) then
        blue(win)
        win:waddstr '      tags:'
        for k, v in tablex.sort(irc.tags) do
            cyan(win)
            if show_raw then k = rawstr(k) else k = scrub(k) end
            win:wmove(ncurses.getyx(win), 12)
            win:waddstr(k)
            if v == '' then
                win:waddstr '\n'
            else
                normal(win)
                win:waddstr ': '
                if show_raw then v = rawstr(v) else v = scrub(v) end
                win:waddstr(v, '\n')
            end
        end
    end

    --
    -- SOURCE
    --
    if irc.source then
        blue(win)
        win:waddstr '    source: '
        normal(win)
        win:waddstr(scrub(irc.source), '\n')
    end

    --
    -- COMMAND
    --
    blue(win)
    win:waddstr '   command: '
    local cmd_color = palette[irc.command] or function() end
    cmd_color(win)
    bold(win)
    win:waddstr(scrub(irc.command))
    bold_(win)

    if not show_raw then
        local name = numeric_names[irc.command]
        if name then
            win:waddstr(' - ', name)
        end
    end
    win:waddstr '\n'

    --
    -- ARGUMENTS
    --
    for i, v in ipairs(irc) do
        blue(win)
        win:waddstr(string.format('%10d: ', i))
        normal(win)
        if show_raw then
            win:waddstr(rawstr(v))
        else
            addircstr(win, v)
        end
        win:waddstr '\n'
    end

    --
    -- DECODED SNOTE BODY
    --
    if snotice ~= nil then
        win:waddstr '\n'
        blue(win)
        win:waddstr(string.format('%10s: ', 'name'))
        magenta(win)
        win:waddstr(snotice.name, '\n')

        for k, v in tablex.sort(snotice) do
            if k ~= 'name' then
                blue(win)
                win:waddstr(k)
                normal(win)
                win:waddstr(scrub(v), '\n')
            end
        end
    end

    win:waddstr '─'
    add_button(win, '[CLOSE]', function() focus = nil end)
    local _, x = ncurses.getyx(win)
    win:waddstr(string.rep('─', tty_width - x))
    win:waddstr '\n'
end

local squelch_commands = {
    PONG = true,
    PING = true,
    AWAY = true,
}

local function draw_messages(win)
    local current_filter
    if input_mode == 'filter' then
        current_filter = editor:content()
    else
        current_filter = filter
    end

    local show_irc
    if current_filter then
        show_irc = function(irc)
            local haystack
            local source = irc.source
            if source then
                haystack = source .. ' ' .. irc.command .. ' ' .. table.concat(irc, ' ')
            else
                haystack = irc.command .. ' ' .. table.concat(irc, ' ')
            end

            local ok, match = pcall(string.match, haystack, current_filter)
            return not ok or match
        end
    elseif hide_snow then
        show_irc = function(irc)
            return (irc.command ~= 'NOTICE' or irc[1] ~= '*')
               and not squelch_commands[irc.command]
        end
    end

    local start = ncurses.getyx(win)
    local rows = math.max(0, tty_height - 1 - start)
    drawing.draw_rotation(win, start, rows, messages, show_irc, render_irc)
end

function M:render(win)
    if focus ~= nil then
        draw_focus(win, focus.irc, focus.snotice)
    end
    draw_messages(win)
end

function M:draw_status() end

return M
