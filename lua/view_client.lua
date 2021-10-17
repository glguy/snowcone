local align = true
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
    if align then
        if irc.source and irc.command == 'NOTICE'
        and irc[1] == '*' and #irc == 2
        and irc[2]:startswith '*** Notice -- ' then
            pretty_source(irc.source)
            magenta()
            bold()
            addstr 'SNOW '
            bold_()
            cyan()
            addstr(':')
            normal()
            addstr(scrub(string.sub(irc[2], 15)))
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
        addstr(string.format('%4.4s', irc.command))
        normal()
    else
        if irc.source then
            addstr(irc.source .. ' ')
        end
        bold()
        local color = palette[irc.command]
        if color then color() end
        addstr(irc.command)
        normal()
    end

    local n = #irc
    for i,arg in ipairs(irc) do
        if i == n and (arg == '' or arg:startswith ':' or arg:match ' ') then
            cyan()
            addstr(' :')
            normal()
            addstr(scrub(arg))
        else
            addstr(' '..scrub(arg))
        end
    end
end

local M = {
    active = true,
}

local previous_buffer = ""
local buffer = ""

local commands = {}

function commands.quote(args)
    snowcone.send_irc(args .. '\r\n')
end

function commands.nettrack(args)
    local name, mask = string.match(args, '(%g+) +(%g+)')
    if name then
        add_network_tracker(name, mask)
    end
end

function commands.filter(args)
    if args == '' then
        filter = nil
    else
        filter = args
    end
end

function commands.sync()
    snowcone.send_irc(counter_sync_commands())
end

function commands.reload()
    assert(loadfile(configuration.lua_filename))()
end

function commands.eval(args)
    local chunk, message = load(args, '=(eval)', 't')
    if chunk then
        local _, ret = pcall(chunk)
        status_message = string.match(tostring(ret), '^[^\n]*')
        normal()
    else
        status_message = string.match(message, '^[^\n]*')
    end
end

local function execute()
    local command, args = string.match(buffer, '^ */(%g*) *(.*)$')
    local impl = commands[command]
    if impl then
        previous_buffer = buffer
        buffer = ''
        status_message = ''
        impl(args)
    else
        status_message = 'unknown command'
    end
end

local keymap = {
    [0x1b] = function() buffer = '' status_message = '' end, -- Esc
    [0x7f] = function() buffer = string.sub(buffer, 1, #buffer - 1) end, -- Del
    [-ncurses.KEY_BACKSPACE] = function() buffer = string.sub(buffer, 1, #buffer - 1) end,
    [0x12] = function() align = not align end, -- ^R
    [-ncurses.KEY_UP] = function() buffer = previous_buffer end,
    [0xd] = execute, -- Enter
}

function M:keypress(key)
    local h = keymap[key]
    if h then
        h()
    elseif 0x14 <= key then
        buffer = buffer .. utf8.char(key)
    else
        buffer = string.format('%s[%d]', buffer, key)
    end
    draw()
end

local rotating_window = require 'rotating_window'

function M:render()

    local rows = math.max(0, tty_height - 2)
    local window = rotating_window.build_window(messages, 'each', rows)
    local clear_line = string.rep(' ', tty_width)

    for y = 0, rows - 1 do
        local entry = window[y]
        if entry == 'divider' then
            yellow()
            mvaddstr(y, 0, string.rep('·', tty_width))
            normal()
        else
            mvaddstr(y, 0, '')
            if window[y] then
                render_irc(window[y])
            end
        end

        local y_end = ncurses.getyx()
        for i = y+1,y_end do
            mvaddstr(i, 0, clear_line)
        end
    end
    cyan()
    mvaddstr(tty_height - 2, 0, buffer)
    draw_global_load('CLICON', conn_tracker)
end

return M
