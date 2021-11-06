local addircstr = require_ 'utils.irc_formatting'
local palette = {
    PRIVMSG = blue,
    NOTICE = cyan,
    JOIN = green,
    PART = yellow,
    QUIT = red,
}

local function pretty_source(source)
    local head, kind = string.match(source, '^(.-)([.!])')
    if kind == '!' then
        cyan()
    else
        yellow()
    end
    addstr(string.format('%16.16s ', head or source))
    normal()
end

local function render_irc(irc)
    if irc.source and irc.command == 'NOTICE'
    and irc[1] == '*' and #irc == 2
    and irc[2]:startswith '*** Notice -- ' then
        pretty_source(irc.source)
        magenta()
        bold()
        add_button('SNOW ', function() focus = irc end, true)
        bold_()
        cyan()
        addstr(':')
        normal()
        addircstr(string.sub(irc[2], 15))
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
    add_button(string.format('%4.4s', irc.command), function() focus=irc end, true)
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
    draw_status = function() end,
}

local rotating_window = require_ 'utils.rotating_window'

local keys = {
    [-ncurses.KEY_PPAGE] = function()
        local elts = math.min(messages.max, messages.n)
        scroll = scroll + math.max(1, tty_height - 1)
        scroll = math.min(scroll, elts - tty_height + 1)
        scroll = math.max(scroll, 0)
    end,
    [-ncurses.KEY_NPAGE] = function()
        scroll = scroll - math.max(1, tty_height - 1)
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

local function draw_focus(irc)
    if irc.tags ~= nil then
        blue()
        addstr('tags:\n')

        for k,v in pairs(irc.tags) do
            cyan()
            addstr('  ' .. k)
            if type(v) == 'string' then
                addstr(': ')
                yellow()
                addstr(v)
            end
            addstr '\n'
        end
    end

    if irc.source then
        blue()
        addstr('source: ')
        normal()
        addstr(irc.source..'\n')
    end

    blue()
    addstr('command: ')
    local cmd_color = palette[irc.command] or function() end
    cmd_color()
    bold()
    addstr(irc.command .. '\n')
    bold_()

    for i, v in ipairs(irc) do
        blue()
        addstr(i .. ': ')
        normal()
        addircstr(v)
        addstr('\n')
    end
    addstr('─')
    add_button('[CLOSE]', function() focus = nil end)
    local _, x = ncurses.getyx()
    addstr(string.rep('─', tty_width - x))
end

local function draw_messages()
    local current_filter
    if input_mode == 'filter' then
        current_filter = editor.rendered
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
    end

    local start = ncurses.getyx()
    local rows = math.max(0, tty_height - 1 - start)
    local window = rotating_window(messages, rows, show_irc)
    local clear_line = string.rep(' ', tty_width)

    for j = 1, rows do
        local entry = window[j]
        local y = start + j - 1
        if entry == 'divider' then
            yellow()
            mvaddstr(y, 0, string.rep('·', tty_width))
            normal()
        elseif entry then
            mvaddstr(y, 0, '')
            render_irc(entry)
            local y_end = ncurses.getyx()
            for i = y+1,y_end do
                mvaddstr(i, 0, clear_line)
            end
        end
    end
end

function M:render()
    if focus ~= nil then
        draw_focus(focus)
    end
    draw_messages()
    draw_global_load('cliconn', conn_tracker)
end

return M