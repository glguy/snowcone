-- A chat buffer of the current network (from ircc/view/buffer.lua).
--
-- t starts talk mode; Ctrl-N and Ctrl-P step through the network's
-- buffers. Click a sender to inspect the message in the console. Viewing a
-- buffer marks it seen and, with the terminal focused, withdraws its
-- notification.

local addircstr  <const> = require 'hub.ui.irc_formatting'
local chat       <const> = require 'hub.features.chat'
local common     <const> = require 'hub.features.common'
local control    <const> = require 'hub.ui.control'
local dispatch   <const> = require 'hub.runtime.dispatch'
local draw       <const> = require 'hub.ui.draw'
local editor     <const> = require 'hub.ui.editor'
local irc_model  <const> = require 'hub.net.irc'
local matching   <const> = require 'hub.lib.matching'
local OrderedMap <const> = require 'hub.lib.OrderedMap'
local scrub      <const> = require 'hub.lib.scrub'

local function chat_renderer(win, msg)
    local text = msg[2] or ''
    local action = msg.command == 'PRIVMSG' and text:match '^\x01ACTION (.*)\x01$'
    addircstr(win, action or text)
end

local renderer = {
    PRIVMSG = chat_renderer,
    NOTICE = chat_renderer,
    WALLOPS = function(win, msg) addircstr(win, msg[1] or '') end,
}
renderer.OPERWALL = renderer.WALLOPS

function renderer.JOIN(win, msg)
    draw.italic(win)
    win:waddstr 'join '
    draw.normal(win)
    win:waddstr(scrub(msg.user or '?'), '@', scrub(msg.host or '?'))
    local account = msg[2]
    if account then
        if account ~= '*' then
            draw.magenta(win)
            win:waddstr ' a:'
            draw.normal(win)
            win:waddstr(scrub(account))
        end
        draw.magenta(win)
        win:waddstr ' r:'
        addircstr(win, msg[3] or '')
    end
end

function renderer.PART(win, msg)
    draw.italic(win)
    win:waddstr 'part '
    addircstr(win, msg[2] or '')
end

function renderer.QUIT(win, msg)
    draw.italic(win)
    win:waddstr 'quit '
    addircstr(win, msg[1] or '')
end

function renderer.NICK(win, msg)
    draw.italic(win)
    win:waddstr 'nick '
    draw.normal(win)
    win:waddstr(scrub(msg[1]))
end

function renderer.KICK(win, msg)
    draw.italic(win)
    win:waddstr 'kick '
    draw.italic_(win)
    win:waddstr(scrub(msg[2] or ''), ': ')
    addircstr(win, msg[3] or '')
end

function renderer.MODE(win, msg)
    draw.italic(win)
    win:waddstr 'mode'
    draw.italic_(win)
    for i = 2, #msg do
        win:waddstr(' ', scrub(msg[i]))
    end
end

function renderer.TOPIC(win, msg)
    draw.italic(win)
    win:waddstr 'topic '
    addircstr(win, msg[2] or '')
end

function renderer.ACCOUNT(win, msg)
    draw.italic(win)
    if msg[1] == '*' then
        win:waddstr 'log-out'
    else
        win:waddstr 'log-in '
        draw.italic_(win)
        win:waddstr(scrub(msg[1] or ''))
    end
end

function renderer.CHGHOST(win, msg)
    draw.italic(win)
    win:waddstr 'host '
    draw.italic_(win)
    win:waddstr(scrub(msg[1] or ''), '@', scrub(msg[2] or ''))
end

local function render_msg(ctx, win, msg)
    local command = msg.command
    local source = msg.nick or (msg.source or '?'):match '^[^.!]*'
    local action = command == 'PRIVMSG' and (msg[2] or ''):match '^\x01ACTION (.*)\x01$'

    if source == '>>>' then
        draw.red(win)
    elseif action then
        draw.blue(win)
    elseif command == 'PRIVMSG' then
        draw.cyan(win)
    elseif command == 'NOTICE' then
        draw.green(win)
    else
        draw.magenta(win)
    end

    ctx.add_button(win, string.format(' %16.16s', scrub(source)), function()
        control.view_state('console').focus = msg
        control.set_view 'console'
    end, true)

    if msg.statusmsg then
        draw.red(win)
        win:waddstr(scrub(msg.statusmsg))
    else
        win:waddstr ' '
    end
    draw.normal(win)

    local h = renderer[command]
    if h then h(win, msg) end
end

local function haystack(msg)
    local parts = {tostring(msg.command), table.concat(msg, ' ')}
    if msg.source then table.insert(parts, 1, msg.source) end
    return table.concat(parts, ' ')
end

-- Buffer names of a network, sorted by folded name
local function sorted_names(net)
    local list = {}
    for key, buffer in pairs(chat.get(net).buffers) do
        table.insert(list, {key, buffer.name})
    end
    table.sort(list, function(a, b) return a[1] < b[1] end)
    return list
end

local function step_buffer(ctx, forward)
    local net = ctx.net
    local names = sorted_names(net)
    if #names == 0 then return end
    local current = control.talk_target(net)
    local key = current and chat.fold(net, current)
    local index
    for i, entry in ipairs(names) do
        if entry[1] == key then index = i end
    end
    if index then
        index = (index - 1 + (forward and 1 or -1)) % #names + 1
    else
        index = 1
    end
    control.set_talk_target(net, names[index][2])
end

local keys = {
    [0x1f & string.byte 'N'] = function(ctx) step_buffer(ctx, true) end,
    [0x1f & string.byte 'P'] = function(ctx) step_buffer(ctx, false) end,
    [string.byte 't'] = function()
        editor.reset(control.editor())
        control.set_input_mode 'talk'
    end,
}

local function scroll_by(ctx, buffer, delta)
    local elts = OrderedMap.size(buffer.messages)
    local scroll = math.min(ctx.vs.scroll + delta, elts - ctx.rows + 1)
    ctx.vs.scroll = math.max(scroll, 0)
end

local function current_buffer(ctx)
    if not (ctx.net and common.enabled(ctx.net, 'chat')) then return nil end
    local target = control.talk_target(ctx.net)
    return target and chat.buffer(ctx.net, target), target
end

return {
    id = 'buffer',
    title = 'buffer',
    scope = 'net',

    render = function(ctx, win)
        if not ctx.net then
            win:waddstr 'No network selected\n'
            return
        end
        if not common.enabled(ctx.net, 'chat') then
            win:waddstr(ctx.net .. ' does not have the chat feature\n')
            return
        end
        local buffer, target = current_buffer(ctx)
        if not buffer then
            win:waddstr(target and ('No buffer ' .. scrub(target) .. '\n') or 'No buffer: /talk <target>\n')
            return
        end

        chat.look(buffer)
        if HUB.state.ui.focus then
            dispatch.route 'notify.dismiss' (ctx.net, target)
        end

        local pattern = control.filter(ctx.id)
        local show
        if pattern then
            show = function(msg) return matching.safematch(haystack(msg), pattern) end
        end
        draw.draw_rotation(win, ctx.vs, 0, ctx.rows, buffer.messages, show, function(w, msg)
            render_msg(ctx, w, msg)
        end)
    end,

    keypress = function(ctx, key)
        if key == -ncurses.KEY_PPAGE or key == -ncurses.KEY_NPAGE
        or key == -ncurses.KEY_UP or key == -ncurses.KEY_DOWN then
            local buffer = current_buffer(ctx)
            if not buffer then return end
            local page = math.max(1, ctx.rows - 1)
            local delta = ({
                [-ncurses.KEY_PPAGE] = page, [-ncurses.KEY_NPAGE] = -page,
                [-ncurses.KEY_UP] = 1, [-ncurses.KEY_DOWN] = -1,
            })[key]
            scroll_by(ctx, buffer, delta)
            return true
        end
        local h = keys[key]
        if h and ctx.net then
            h(ctx)
            return true
        end
    end,

    -- The target, coloured by whether we can reach it, then buffers with
    -- unseen messages (magenta for mentions)
    status = function(ctx, win)
        local net = ctx.net
        if not (net and common.enabled(net, 'chat')) then return end
        local rec = HUB.state.nets[net]
        local irc = rec.irc
        local target = control.talk_target(net)

        if target then
            ctx.fragment(win)
            if not irc or rec.phase ~= 'connected' then
                draw.yellow(win)
            elseif irc_model.is_channel_name(irc, target) then
                if irc_model.get_channel(irc, target) then draw.green(win) else draw.red(win) end
            elseif irc_model.has_monitor(irc) and irc_model.get_monitor(irc, target) then
                local entry = irc_model.get_monitor(irc, target)
                if entry.user then
                    if entry.user.away then draw.magenta(win) else draw.green(win) end
                else
                    draw.red(win)
                end
            else
                draw.yellow(win)
            end
            local buffer = chat.buffer(net, target)
            draw.bold(win)
            win:waddstr(scrub(buffer and buffer.name or target))
            draw.normal(win)
        end

        for _, entry in ipairs(sorted_names(net)) do
            local buffer = chat.get(net).buffers[entry[1]]
            if buffer.activity > 0 then
                ctx.fragment(win)
                if buffer.mention then draw.magenta(win) else draw.yellow(win) end
                local name = buffer.name
                local _, x1 = ncurses.getyx(win)
                win:waddstr(scrub(name))
                local _, x2 = ncurses.getyx(win)
                ctx.add_click(tty_height - 1, x1, x2, function()
                    control.set_talk_target(net, name)
                end)
            end
        end
        draw.normal(win)
    end,
}
