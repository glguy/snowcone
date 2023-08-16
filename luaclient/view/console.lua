local addircstr = require_ 'utils.irc_formatting'
local parse_snote = require 'utils.parse_snote'
local drawing = require 'utils.drawing'
local numerics = require 'utils.numerics'
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

local function pretty_source(source)
    if source == '>>>' then
        red()
    else
        local head, kind = string.match(source, '^(.-)([.!])')
        source = head or source
        if kind == '!' then
            cyan()
        else
            yellow()
        end
    end
    addstr(string.format('%16.16s ', source))
    normal()
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

local function render_irc(irc)
    addstr ' '

    local snote_text = match_snotice(irc)
    if snote_text ~= nil then
        pretty_source(irc.source)
        magenta()
        bold()
        add_button('SNOW ', function() set_focus(irc) end, true)
        bold_()
        cyan()
        addstr(':')
        normal()
        addircstr(snote_text)
        return
    end

    if irc.source then
        pretty_source(irc.source)
    else
        addstr(string.rep(' ', 17))
    end

    local color = palette[irc.command]
    if color then color() end
    bold()
    add_button(string.format('%4.4s', irc.command), function() set_focus(irc) end, true)
    normal()

    local n = #irc
    for i,arg in ipairs(irc) do
        if i == n and (arg == '' or arg:startswith ':' or arg:match ' ') then
            cyan()
            addstr(' :')
            normal()
            addircstr(arg)
        else
            addircstr(' '..arg)
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
    [meta 'h'] = function() hide_snow = not hide_snow end,
    [meta 'r'] = function() show_raw = not show_raw end,
    [string.byte('t')] = function()
        if talk_target ~= nil then
            editor:reset()
            input_mode = 'talk'
        end
    end,
}

function M:keypress(key)
    local h = keys[key]
    if h then
        h()
        draw()
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

local function draw_focus(irc, snotice)

    --
    -- MESSAGE TAGS
    --
    if next(irc.tags) then
        blue()
        addstr('      tags:')
        for k, v in tablex.sort(irc.tags) do
            cyan()
            if show_raw then k = rawstr(k) end
            mvaddstr(ncurses.getyx(), 12, k)
            if type(v) == 'string' then
                addstr(': ')
                normal()
                if show_raw then v = rawstr(v) end
                addstr(v .. '\n')
            else
                addstr('\n')
            end
        end
    end

    --
    -- SOURCE
    --
    if irc.source then
        blue()
        addstr('    source: ')
        normal()
        addstr(irc.source..'\n')
    end

    --
    -- COMMAND
    --
    blue()
    addstr('   command: ')
    local cmd_color = palette[irc.command] or function() end
    cmd_color()
    bold()
    addstr(irc.command)
    bold_()

    if not show_raw then
        local name = numeric_names[irc.command]
        if name then
            addstr(' - ' .. name)
        end
    end
    addstr('\n')

    --
    -- ARGUMENTS
    --
    for i, v in ipairs(irc) do
        blue()
        addstr(string.format('%10d: ', i))
        normal()
        if show_raw then
            addstr(rawstr(v))
        else
            addircstr(v)
        end
        addstr('\n')
    end

    --
    -- DECODED SNOTE BODY
    --
    if snotice ~= nil then
        addstr('\n')
        blue()
        addstr(string.format('%10s: ', 'name'))
        magenta()
        addstr(snotice.name .. '\n')

        for k, v in tablex.sort(snotice) do
            if k ~= 'name' then
                blue()
                addstr(string.format('%10s: ', k))
                normal()
                addstr(v .. '\n')
            end
        end
    end

    addstr('─')
    add_button('[CLOSE]', function() focus = nil end)
    local _, x = ncurses.getyx()
    addstr(string.rep('─', tty_width - x))
end

local function draw_messages()
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
               and irc.command ~= 'PING'
               and irc.command ~= 'PONG'
        end
    end

    local start = ncurses.getyx()
    local rows = math.max(0, tty_height - 1 - start)
    drawing.draw_rotation(start, rows, messages, show_irc, render_irc)
end

function M:render()
    if focus ~= nil then
        draw_focus(focus.irc, focus.snotice)
    end
    draw_messages()
    draw_global_load()
end

function M:draw_status() end

return M
