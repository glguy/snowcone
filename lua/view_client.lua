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

local buffer = ""

local commands = {}

function commands.quote(args)
    send_irc(args .. '\r\n')
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

function commands.eval(args)
    local chunk, message = load(args, '=(eval)', 't')
    if chunk == 'fail' then
        status_message = string.match(message, '^[^\n]*')
    else
        local res, err = pcall(chunk)
        if not res then
            status_message = string.match(err, '^[^\n]*')
        end
    end
end

local function execute()
    local command, args = string.match(buffer, '^ */(%g*) *(.*)$')
    local impl = commands[command]
    if impl then
        buffer = ''
        status_message = ''
        impl(args)
    else
        status_message = 'unknown command'
    end
    draw()
end

function M:keypress(key)
    if key == 0x1b then
        buffer = ''
        status_message = ''
    elseif key == 0x7f or key == -ncurses.KEY_BACKSPACE then
        buffer = string.sub(buffer, 1, #buffer - 1)
    elseif key == 0x12 then
        align = not align
    elseif 0x14 <= key then
        buffer = buffer .. utf8.char(key)
    elseif key == 0xd then
        execute()
    else
        buffer = string.format('%s[%d]', buffer, key)
    end
    draw()
end

function M:render()

    local window = {}
    local clear_string = string.rep(' ', tty_width)

    local n = 0
    local rows = math.max(1, tty_height - 2)

    for _, entry in messages:each() do
        local y = (messages_n-1-n) % rows
        window[y] = entry
        n = n + 1
        if n >= rows-1 then break end
    end

    window[messages_n % rows] = 'divider'

    for y = 0, rows - 1 do
        local entry = window[y]
        if entry == 'divider' then
            yellow()
            mvaddstr(y, 0, string.rep('·', tty_width))
            normal()
        else
            mvaddstr(y, 0, clear_string)
            mvaddstr(y, 0, '')
            render_irc(window[y])
        end
    end
    cyan()
    mvaddstr(tty_height - 2, 0, buffer)
    draw_global_load('CLICON', conn_tracker)
end

return M
