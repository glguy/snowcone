local tablex = require 'pl.tablex'

local addircstr = require_ 'utils.irc_formatting'
local drawing = require 'utils.drawing'
local scrub = require 'utils.scrub'
local split_nuh   = require_ 'utils.split_nick_user_host'

local hscroll = 0

local function chat_renderer(irc)
    local action = 'PRIVMSG' == irc.command and irc[2]:match '^\x01ACTION (.*)\x01$'
    local text = action or irc[2]
    addircstr(text:sub(hscroll))
end

local command_renderer = {
    PRIVMSG = chat_renderer,
    NOTICE = chat_renderer,
}

function command_renderer.JOIN(irc)
    italic()
    local _, u, h = split_nuh(irc.source)
    addstr('joined ', scrub(u), '@', scrub(h))
    local account = irc[2]
    if account then
        if '*' ~= account then
            addstr(' <', scrub(account), '>')
        end
        addstr ' '
        addircstr(irc[3])
    end
end

function command_renderer.PART(irc)
    italic()
    addstr 'parted '
    addircstr(irc[1])
end

function command_renderer.QUIT(irc)
    italic()
    addstr 'quit '
    addircstr(irc[1])
end

function command_renderer.NICK(irc)
    italic()
    addstr('set nick ', scrub(irc[1]))
end

function command_renderer.KICK(irc)
    italic()
    addstr('kicked ', scrub(irc[2]), ': ')
    addircstr(irc[3])
end

function command_renderer.MODE(irc)
    italic()
    addstr 'set mode'
    for i = 2, #irc do
        addstr(' ', scrub(irc[i]))
    end
end

function command_renderer.TOPIC(irc)
    italic()
    addstr 'set topic '
    addircstr(irc[2])
end

function command_renderer.ACCOUNT(irc)
    italic()
    local account = irc[1]
    if '*' == account then
        addstr 'logged out'
    else
        addstr('logged in as ', scrub(account))
    end
end

function command_renderer.CHGHOST(irc)
    italic()
    addstr('set host ', scrub(irc[1]), '@', scrub(irc[2]))
end

local function render_irc(irc)
    local command = irc.command
    local source = irc.source:match '^(.-)([.!])' or irc.source

    local action = 'PRIVMSG' == command and irc[2]:match '^\x01ACTION (.*)\x01$'

    if source == '>>>' then
        red()
    elseif action then
        blue()
    elseif command == 'PRIVMSG' then
        cyan()
    elseif command == 'NOTICE' then
        green()
    else
        magenta()
    end

    add_button(string.format(' %16.16s', scrub(source)), function()
        focus = {irc=irc}
        view = 'console'
    end, true)

    local statusmsg = irc.statusmsg
    if statusmsg then
        red()
        addstr(scrub(statusmsg))
    else
        addstr ' '
    end

    local h = command_renderer[irc.command]
    if h then h(irc) end
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
    [-ncurses.KEY_RIGHT] = function()
        local scroll_unit = math.max(1, tty_width - 26)
        hscroll = math.max(0, math.min(512 - scroll_unit, hscroll + scroll_unit))
    end,
    [-ncurses.KEY_LEFT] = function()
        local scroll_unit = math.max(1, tty_width - 26)
        hscroll = math.max(0, hscroll - scroll_unit)
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
        input_mode = 'talk'
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

local function draw_messages(buffer)
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

            print(haystack, current_filter)
            return matching.safematch(haystack, current_filter)
        end
    end

    local start = ncurses.getyx()
    local rows = math.max(0, tty_height - 1 - start)

    buffer:look()

    drawing.draw_rotation(start, rows, buffer.messages, show_irc, render_irc)
end

function M:render()
    local buffer = buffers[talk_target]
    if buffer then
        if terminal_focus and notification_muted[talk_target] then
            require(configuration.notification_module).dismiss(notification_muted[talk_target])
            notification_muted[talk_target] = nil
        end
        draw_messages(buffer)
    end
end

function M:draw_status()
    -- not connected
    if not irc_state or irc_state.phase ~= 'connected' then
        yellow()

    -- Render joined channels in green and stale buffers in red
    elseif irc_state:is_channel_name(talk_target) then
        if irc_state:get_channel(talk_target) then
            green()
        else
            red()
        end

    -- render online users in green, offline in red
    elseif irc_state:has_monitor() and irc_state:is_monitored(talk_target) then
        local entry = irc_state:get_monitor(talk_target)
        if entry.user then
            if entry.user.away then
                magenta()
            else
                green()
            end
        else
            red()
        end

    -- When monitor isn't available indicate uncertainty with yellow
    else
        yellow()
    end

    do
        local buffer = buffers[talk_target]
        local name = buffer and buffer.name or talk_target
        bold()
        addstr(name, '')
        normal()
    end

    -- render channel names with unseen messages in yellow
    for _, buffer in tablex.sort(buffers) do
        if buffer.seen < buffer.messages.n then
            if buffer.mention then
                magenta()
            else
                yellow()
            end
            addstr(buffer.name, '')
        end
    end
end

return M
