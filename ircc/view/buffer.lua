local tablex = require 'pl.tablex'

local addircstr = require 'utils.irc_formatting'
local drawing = require 'utils.drawing'
local scrub = require 'utils.scrub'
local split_nuh   = require 'utils.split_nick_user_host'

local function chat_renderer(win, irc)
    local action = 'PRIVMSG' == irc.command and irc[2]:match '^\x01ACTION (.*)\x01$'
    local text = action or irc[2]
    addircstr(win, text)
end

local command_renderer = {
    PRIVMSG = chat_renderer,
    NOTICE = chat_renderer,
}

function command_renderer.JOIN(win, irc)
    italic(win)
    local _, u, h = split_nuh(irc.source)
    win:waddstr('join ')
    normal(win)
    win:waddstr(scrub(u), '@', scrub(h))
    local account = irc[2]
    if account then
        if '*' ~= account then
            magenta(win)
            win:waddstr(' a:')
            normal(win)
            win:waddstr(scrub(account))
        end
        magenta(win)
        win:waddstr ' r:'
        addircstr(win, irc[3])
    end
end

function command_renderer.PART(win, irc)
    italic(win)
    win:waddstr 'part '
    addircstr(win, irc[1])
end

function command_renderer.QUIT(win, irc)
    italic(win)
    win:waddstr 'quit '
    addircstr(win, irc[1])
end

function command_renderer.NICK(win, irc)
    italic(win)
    win:waddstr('nick ')
    normal(win)
    win:waddstr(scrub(irc[1]))
end

function command_renderer.KICK(win, irc)
    italic(win)
    win:waddstr('kick ')
    italic_(win)
    win:waddstr(scrub(irc[2]), ': ')
    addircstr(win, irc[3])
end

function command_renderer.MODE(win, irc)
    italic(win)
    win:waddstr 'mode'
    italic_(win)
    for i = 2, #irc do
        win:waddstr(' ', scrub(irc[i]))
    end
end

function command_renderer.TOPIC(win, irc)
    italic(win)
    win:waddstr 'topic '
    addircstr(win, irc[2])
end

function command_renderer.ACCOUNT(win, irc)
    italic(win)
    local account = irc[1]
    if '*' == account then
        win:waddstr 'log-out'
    else
        win:waddstr('log-in ')
        italic_(win)
        win:waddstr(scrub(account))
    end
end

function command_renderer.CHGHOST(win, irc)
    italic(win)
    win:waddstr('host ')
    italic_(win)
    win:waddstr(scrub(irc[1]), '@', scrub(irc[2]))
end

local function render_irc(win, irc)
    local command = irc.command
    local source = irc.source:match '^(.-)([.!])' or irc.source

    local action = 'PRIVMSG' == command and irc[2]:match '^\x01ACTION (.*)\x01$'

    if source == '>>>' then
        red(win)
    elseif action then
        blue(win)
    elseif command == 'PRIVMSG' then
        cyan(win)
    elseif command == 'NOTICE' then
        green(win)
    else
        magenta(win)
    end

    add_button(win, string.format(' %16.16s', scrub(source)), function()
        focus = {irc=irc}
        set_view 'console'
    end, true)

    local statusmsg = irc.statusmsg
    if statusmsg then
        red(win)
        win:waddstr(scrub(statusmsg))
    else
        win:waddstr ' '
    end

    local h = command_renderer[irc.command]
    if h then h(win, irc) end
end

local M = {
    active = true,
    title = 'buffer',
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
    [-ncurses.KEY_UP] = function()
        local elts = math.min(messages.max, messages.n)
        scroll = scroll + 1
        scroll = math.min(scroll, elts - tty_height + 2)
        scroll = math.max(scroll, 0)
    end,
    [-ncurses.KEY_DOWN] = function()
        scroll = scroll - 1
        scroll = math.max(scroll, 0)
    end,

    -- next buffer (alphabetical)
    [ctrl 'N'] = function()
        local current = talk_target
        local first_target
        for k, _ in tablex.sort(buffers) do
            if current < k then
                set_talk_target(k)
                return
            end
            if not first_target then
                first_target = k
            end
        end
        if first_target then
            set_talk_target(first_target)
        end
    end,

    -- previous buffer (alphabetical)
    [ctrl 'P'] = function()
        local current = talk_target
        local first_target
        local function backward(x,y) return x > y end
        for k, _ in tablex.sort(buffers, backward) do
            if current > k then
                set_talk_target(k)
                return
            end
            if not first_target then
                first_target = k
            end
        end
        if first_target then
            set_talk_target(first_target)
        end
    end,

    -- enter talk input mode
    [string.byte('t')] = function()
        editor:reset()
        set_input_mode 'talk'
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

local function draw_messages(win, buffer)
    local current_filter = matching.current_pattern()
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
            return matching.safematch(haystack, current_filter)
        end
    end

    local start = ncurses.getyx(win)
    local rows = math.max(0, tty_height - 1 - start)

    buffer:look()

    drawing.draw_rotation(win, start, rows, buffer.messages, show_irc, render_irc)
end

function M:render(win)
    local buffer = buffers[talk_target]
    if buffer then
        if terminal_focus and configuration.notifications and notification_muted[talk_target] then
            require(configuration.notifications.module).dismiss(notification_muted[talk_target])
            notification_muted[talk_target] = nil
        end
        draw_messages(win, buffer)
    end
end

function M:draw_status(win)
    -- not connected
    if not irc_state or irc_state.phase ~= 'connected' then
        yellow(win)

    -- Render joined channels in green and stale buffers in red
    elseif irc_state:is_channel_name(talk_target) then
        if irc_state:get_channel(talk_target) then
            green(win)
        else
            red(win)
        end

    -- render online users in green, offline in red
    elseif irc_state:has_monitor() and irc_state:is_monitored(talk_target) then
        local entry = irc_state:get_monitor(talk_target)
        if entry.user then
            if entry.user.away then
                magenta(win)
            else
                green(win)
            end
        else
            red(win)
        end

    -- When monitor isn't available indicate uncertainty with yellow
    else
        yellow(win)
    end

    do
        local buffer = buffers[talk_target]
        local name = buffer and buffer.name or talk_target
        bold(win)
        win:waddstr(name, '')
        normal(win)
    end

    -- render channel names with unseen messages in yellow
    for _, buffer in tablex.sort(buffers) do
        if 0 < buffer.activity then
            if buffer.mention then
                magenta(win)
            else
                yellow(win)
            end
            win:waddstr(buffer.name, '')
        end
    end
end

return M
