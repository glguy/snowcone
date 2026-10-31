-- A chat buffer of the current network.
--
-- t starts talk mode and a action mode, which tell the buffer we are
-- typing; Meta-T starts quiet talk mode, which doesn't; T starts notice
-- mode. n and p step through the network's buffers; Meta-H hides joins,
-- parts, quits, nick changes, account changes and host changes. Click a
-- sender to inspect the message in the detail pane. A reply (the +reply
-- tag) starts with ↩: click it to scroll to the message it answers, which
-- is highlighted until Esc. Click a channel's name in the status bar for
-- its information, a nick's for its WHOIS. After the name, the two who
-- most recently started typing there (not those who paused).
-- Viewing a buffer marks it seen and, with the terminal focused,
-- withdraws its notification.
-- View state: scroll, hscroll, hide_presence, highlight (a message).

local addircstr  <const> = require 'hub.ui.irc_formatting'
local chat       <const> = require 'hub.features.chat'
local common     <const> = require 'hub.features.common'
local control    <const> = require 'hub.ui.control'
local dispatch   <const> = require 'hub.runtime.dispatch'
local draw       <const> = require 'hub.ui.draw'
local editor     <const> = require 'hub.ui.editor'
local irc_model  <const> = require 'hub.net.irc'
local log        <const> = require 'hub.runtime.log'
local matching   <const> = require 'hub.lib.matching'
local OrderedMap <const> = require 'hub.lib.OrderedMap'
local scrub      <const> = require 'hub.lib.scrub'

-- How many of those typing the status bar names
local typing_shown <const> = 2

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

-- Scroll to the message with msgid `id`, in the middle of the screen when
-- it can be, and highlight it
local function jump(ctx, buffer, id)
    local k = OrderedMap.number(buffer.messages, id)
    if not k then
        log.add('error', 'the message replied to is not in this buffer')
        return
    end
    local vs = ctx.vs
    -- a filter could hide it
    control.set_filter(ctx.id, nil)
    -- scrolled by s, the newest shown is entry last - s, on the row above
    -- the divider
    local s = OrderedMap.last(buffer.messages) - k - (ctx.rows - 2) // 2
    vs.scroll = math.max(0, math.min(s, vs.max_scroll or s))
    vs.pin = nil
    vs.highlight = OrderedMap.get(buffer.messages, k)
end

local function render_msg(ctx, win, buffer, msg)
    local command = msg.command
    local source = msg.nick or (msg.source or '?'):match '^[^.!]*'
    local action = command == 'PRIVMSG' and (msg[2] or ''):match '^\x01ACTION (.*)\x01$'

    if source == '>>>' then
        local color
        source, color = draw.outbound(msg)
        color(win)
    elseif action then
        draw.blue(win)
    elseif command == 'PRIVMSG' then
        draw.cyan(win)
    elseif command == 'NOTICE' then
        draw.green(win)
    else
        draw.magenta(win)
    end

    -- the highlighted or inspected message shows its sender as a button
    -- would
    local detail = control.detail()
    local marked = msg == ctx.vs.highlight or detail and detail.data == msg
    ctx.add_button(win, string.format(' %16.16s', scrub(source)), function()
        control.open_detail('message', ctx.net, msg)
    end, not marked)

    if msg.statusmsg then
        draw.red(win)
        win:waddstr(scrub(msg.statusmsg))
    else
        win:waddstr ' '
    end
    draw.normal(win)

    local parent = msg.tags and msg.tags['+reply']
    if parent then
        ctx.add_button(win, '↩', function() jump(ctx, buffer, parent) end, true)
        win:waddstr ' '
    end

    local h = renderer[command]
    if h then h(win, msg) end
end

-- Commands Meta-H hides: comings, goings and identity changes
local presence_commands <const> = {
    JOIN = true,
    PART = true,
    QUIT = true,
    NICK = true,
    ACCOUNT = true,
    CHGHOST = true,
}

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
    [-string.byte 'h'] = function(ctx) ctx.vs.hide_presence = not ctx.vs.hide_presence end,
    [string.byte 'n'] = function(ctx) step_buffer(ctx, true) end,
    [string.byte 'p'] = function(ctx) step_buffer(ctx, false) end,
    [string.byte 't'] = function()
        editor.reset(control.editor())
        control.set_input_mode 'talk'
    end,
    [-string.byte 't'] = function()
        editor.reset(control.editor())
        control.set_input_mode 'quiet'
    end,
    [string.byte 'a'] = function()
        editor.reset(control.editor())
        control.set_input_mode 'action'
    end,
    [string.byte 'T'] = function()
        editor.reset(control.editor())
        control.set_input_mode 'notice'
    end,
}

local function current_buffer(ctx)
    if not (ctx.net and common.enabled(ctx.net, 'chat')) then return nil end
    local target = control.talk_target(ctx.net)
    return target and chat.buffer(ctx.net, target), target
end

return {
    id = 'buffer',
    title = 'buffer',
    scope = 'net',
    feature = 'chat',

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
        elseif ctx.vs.hide_presence then
            show = function(msg) return not presence_commands[msg.command] end
        end
        draw.draw_rotation(win, ctx.vs, 0, ctx.rows, buffer.messages, show, function(w, msg)
            render_msg(ctx, w, buffer, msg)
        end)
    end,

    -- Esc clears the highlight; it also scrolls back to the newest
    reset = function(vs) vs.highlight = nil end,

    modes = function(ctx)
        return {ctx.vs.hide_presence and 'hide' or nil}
    end,

    keypress = function(ctx, key)
        local h = keys[key]
        if h and ctx.net then
            h(ctx)
            return true
        end
    end,

    -- The target, colored by whether we can reach it, who is typing there,
    -- then buffers with unseen messages (magenta for mentions)
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
                ---@cast entry -nil found by the condition above
                if entry.user then
                    if entry.user.away then draw.magenta(win) else draw.green(win) end
                else
                    draw.red(win)
                end
            else
                draw.yellow(win)
            end
            local buffer = chat.buffer(net, target)
            local name = buffer and buffer.name or target
            local _, x1 = ncurses.getyx(win)
            draw.bold(win)
            win:waddstr(scrub(name))
            draw.normal(win)
            -- a channel's name opens its information, a nick's its WHOIS
            if irc then
                local _, x2 = ncurses.getyx(win)
                if irc_model.is_channel_name(irc, name) then
                    ctx.add_click(tty_height - 1, x1, x2, function()
                        chat.channel_info(net, name)
                        control.open_detail('channel', net, {name = name})
                    end)
                else
                    ctx.add_click(tty_height - 1, x1, x2, function() chat.whois(net, name) end)
                end
            end

            local nicks = {}
            for _, entry in ipairs(buffer and chat.typing(net, buffer) or {}) do
                if #nicks == typing_shown then break end
                if entry.state == 'active' then
                    table.insert(nicks, scrub(entry.nick))
                end
            end
            if #nicks > 0 then
                ctx.fragment(win)
                draw.italic(win)
                win:waddstr(table.concat(nicks, ', '), '…')
                draw.normal(win)
            end
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

    subscribe = function(sub)
        sub.on('chat.focus', function(ev)
            control.set_current_net(ev.net)
            control.set_talk_target(ev.net, ev.target)
            control.set_view 'buffer'
        end)
        -- closing the shown buffer moves to one with a mention, else back
        -- to the previous one (as after Meta-A into a query), else one
        -- with activity, else the next by name; Meta-S no longer goes
        -- back to a closed buffer
        sub.on('chat.buffer', function(ev)
            if ev.opened then return end
            local net = ev.net
            local key = chat.fold(net, ev.target)
            local vs = control.view_state 'buffer'
            local previous = vs.previous and vs.previous[net]
            if previous and chat.fold(net, previous) == key then
                previous = nil
                vs.previous[net] = nil
            end
            local current = control.talk_target(net)
            if current and chat.fold(net, current) == key then
                local best = chat.next_buffer(net, key, true)
                if not (best and best.mention) then
                    best = previous and chat.buffer(net, previous)
                        or best or chat.next_buffer(net, key)
                end
                control.set_talk_target(net, best and best.name)
                if best and previous and chat.fold(net, previous) == chat.fold(net, best.name) then
                    previous = nil
                end
                vs.previous[net] = previous
            end
        end)
    end,
}
