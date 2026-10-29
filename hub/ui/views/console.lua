-- Raw IRC traffic of the current network.
--
-- Click a command to inspect the message above the log (a server notice
-- also shows its parsed fields). Meta-H hides
-- server notices and PING/PONG/AWAY; Meta-R shows inspected values raw;
-- Meta-G switches between the current network and all networks
-- interleaved, with a network column.
-- View state: scroll, hscroll, filter, focus (the inspected message),
-- hide_snow, show_raw, all.

local addircstr     <const> = require 'hub.ui.irc_formatting'
local control       <const> = require 'hub.ui.control'
local draw          <const> = require 'hub.ui.draw'
local matching      <const> = require 'hub.lib.matching'
local numerics      <const> = require 'hub.lib.numerics'
local parse_snote   <const> = require 'hub.features.snotice.parse'
local scrub         <const> = require 'hub.lib.scrub'
local tablex        <const> = require 'pl.tablex'

local meta <const> = function(x) return -string.byte(x) end

local palette = {
    PRIVMSG = draw.blue,
    NOTICE = draw.cyan,
    JOIN = draw.green,
    PART = draw.yellow,
    QUIT = draw.magenta,
}

-- Names of numerics for the inspector; errors are red in the log
local numeric_names = {}
for name, numeric in pairs(numerics) do
    numeric_names[numeric] = name
    if name:sub(1, 4) == 'ERR_' then
        palette[numeric] = draw.red
    end
end

local function pretty_source(win, source, msg)
    if source == '>>>' then
        local colour
        source, colour = draw.outbound(msg)
        colour(win)
    else
        local head, kind = string.match(source, '^(.-)([.!])')
        source = head or source
        if kind == '!' then
            draw.cyan(win)
        else
            draw.yellow(win)
        end
    end
    win:waddstr(string.format(' %16.16s ', scrub(source)))
    draw.normal(win)
end

-- The body of a server notice, without its header
local function match_snotice(msg)
    if msg.source and msg.command == 'NOTICE'
    and msg[1] == '*' and #msg == 2
    and msg[2]:sub(1, 14) == '*** Notice -- ' then
        return msg[2]:sub(15)
    end
end

local function render_msg(ctx, win, msg)
    local function inspect()
        ctx.vs.focus = msg
    end

    local snote_text = match_snotice(msg)
    if snote_text ~= nil then
        pretty_source(win, msg.source, msg)
        draw.magenta(win)
        draw.bold(win)
        ctx.add_button(win, 'SNOW ', inspect, true)
        draw.bold_(win)
        draw.cyan(win)
        win:waddstr ':'
        draw.normal(win)
        addircstr(win, snote_text:sub(1, 400))
        return
    end

    if msg.source then
        pretty_source(win, msg.source, msg)
    else
        win:waddstr(string.rep(' ', 18))
    end

    local color = palette[msg.command]
    if color then color(win) end
    draw.bold(win)
    ctx.add_button(win, string.format('%4.4s', msg.command), inspect, true)
    draw.normal(win)

    local n = #msg
    for i, arg in ipairs(msg) do
        if i == n and (arg == '' or arg:sub(1, 1) == ':' or arg:find ' ') then
            draw.cyan(win)
            win:waddstr ' :'
            draw.normal(win)
            addircstr(win, arg:sub(1, 400))
        else
            addircstr(win, ' ' .. arg)
        end
    end
end

local escapes <const> = {
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

--- The parsed form of a server notice (without the time, which the
--- message shows), or nil for any other message.
local function decode(msg)
    local text = match_snotice(msg)
    return text and parse_snote(msg.source, text)
end

local function draw_focus(ctx, win, msg)
    local show_raw = ctx.vs.show_raw

    if next(msg.tags) then
        draw.blue(win)
        win:waddstr '      tags:'
        for k, v in tablex.sort(msg.tags) do
            draw.cyan(win)
            win:wmove(ncurses.getyx(win), 12)
            win:waddstr(show_raw and rawstr(k) or scrub(k))
            if v == '' or v == true then
                win:waddstr '\n'
            else
                draw.normal(win)
                win:waddstr ': '
                win:waddstr(show_raw and rawstr(v) or scrub(v), '\n')
            end
        end
    end

    if msg.source then
        draw.blue(win)
        win:waddstr '    source: '
        draw.normal(win)
        win:waddstr(scrub(msg.source), '\n')
    end

    local delivery = msg.delivery
    if delivery then
        draw.blue(win)
        win:waddstr '  delivery: '
        draw.normal(win)
        if delivery.state == 'sent' then
            win:waddstr(string.format('sent after %.1f s in the queue\n', delivery.delay))
        else
            win:waddstr(delivery.state, '\n')
        end
    end

    draw.blue(win)
    win:waddstr '   command: '
    local cmd_color = palette[msg.command]
    if cmd_color then cmd_color(win) end
    draw.bold(win)
    win:waddstr(scrub(tostring(msg.command)))
    draw.bold_(win)
    if not show_raw then
        local name = numeric_names[msg.command]
        if name then
            win:waddstr(' - ', name)
        end
    end
    win:waddstr '\n'

    for i, v in ipairs(msg) do
        draw.blue(win)
        win:waddstr(string.format('%10d: ', i))
        draw.normal(win)
        if show_raw then
            win:waddstr(rawstr(v))
        else
            addircstr(win, v)
        end
        win:waddstr '\n'
    end

    -- a server notice also shows what the parser made of it
    local note = decode(msg)
    if note then
        win:waddstr '\n'
        draw.blue(win)
        win:waddstr(string.format('%10s: ', 'name'))
        draw.magenta(win)
        win:waddstr(note.name, '\n')
        for k, v in tablex.sort(note) do
            if k ~= 'name' then
                draw.blue(win)
                win:waddstr(string.format('%10s: ', k))
                draw.normal(win)
                win:waddstr(show_raw and rawstr(tostring(v)) or scrub(tostring(v)), '\n')
            end
        end
    end

    win:waddstr '─'
    ctx.add_button(win, '[CLOSE]', function() ctx.vs.focus = nil end)
    local _, x = ncurses.getyx(win)
    win:waddstr(string.rep('─', math.max(0, ctx.cols - x)))
    win:waddstr '\n'
end

local squelch_commands <const> = {
    PONG = true,
    PING = true,
    AWAY = true,
}

local function haystack(msg)
    local parts = {tostring(msg.command), table.concat(msg, ' ')}
    if msg.source then
        table.insert(parts, 1, msg.source)
    end
    return table.concat(parts, ' ')
end

-- The ring to show. In all-networks mode entries are {net, msg}; the
-- per-network rings hold messages directly.
local function console_of(ctx)
    if ctx.vs.all then
        return HUB.state.console_all
    end
    local rec = ctx.net and HUB.state.nets[ctx.net]
    return rec and rec.console
end

local keys = {
    [meta 'h'] = function(ctx) ctx.vs.hide_snow = not ctx.vs.hide_snow end,
    [meta 'r'] = function(ctx) ctx.vs.show_raw = not ctx.vs.show_raw end,
    [meta 'g'] = function(ctx)
        ctx.vs.all = not ctx.vs.all
        ctx.vs.scroll = 0
    end,
}

return {
    id = 'console',
    decode = decode,
    title = 'console',
    scope = 'net',

    modes = function(ctx)
        local vs = ctx.vs
        local modes = {}
        if vs.hide_snow then table.insert(modes, 'hide') end
        if vs.show_raw then table.insert(modes, 'raw') end
        if vs.all then table.insert(modes, 'all') end
        return modes
    end,

    render = function(ctx, win)
        local data = console_of(ctx)
        if not data then
            win:waddstr 'No network selected\n'
            return
        end

        if ctx.vs.focus then
            draw_focus(ctx, win, ctx.vs.focus)
        end

        local all = ctx.vs.all
        local pattern = control.filter(ctx.id)
        local show
        if pattern then
            show = function(msg)
                local text = haystack(msg)
                if all then text = msg.net .. ' ' .. haystack(msg.msg) end
                return matching.safematch(text, pattern)
            end
        elseif ctx.vs.hide_snow then
            show = function(msg)
                if all then msg = msg.msg end
                return (msg.command ~= 'NOTICE' or msg[1] ~= '*')
                   and not squelch_commands[msg.command]
            end
        end

        local start = ncurses.getyx(win)
        local rows = math.max(0, ctx.rows - start)
        draw.draw_rotation(win, ctx.vs, start, rows, data, show, function(w, entry)
            if all then
                draw.bold(w)
                w:waddstr(string.format(' %-8.8s', entry.net))
                draw.normal(w)
                entry = entry.msg
            end
            render_msg(ctx, w, entry)
        end)
    end,

    keypress = function(ctx, key)
        local h = keys[key]
        if h then
            h(ctx)
            return true
        end
    end,
}
