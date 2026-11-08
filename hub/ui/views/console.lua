-- Raw IRC traffic of the current network.
--
-- Click a sender to inspect the message in the detail pane
-- (ui/details/message.lua), as in a buffer. Meta-H hides server notices and
-- PING/PONG/AWAY; Meta-G switches between the current network and all
-- networks interleaved, with a network column.
-- View state: scroll, hscroll, filter, hide_snow, all, reveal (a message
-- to scroll to on the next frame; ui/details/message.lua's [console]).

local addircstr     <const> = require 'hub.ui.irc_formatting'
local control       <const> = require 'hub.ui.control'
local draw          <const> = require 'hub.ui.draw'
local matching      <const> = require 'hub.lib.matching'
local message       <const> = require 'hub.ui.details.message'
local meta          <const> = require 'hub.ui.keys'.meta
local OrderedMap    <const> = require 'hub.lib.OrderedMap'
local scrub         <const> = require 'hub.lib.scrub'

-- The source column, a button that inspects the message; blank, but
-- still a button, for a message without a source
local function source_button(ctx, win, msg, inspect, plain)
    local source = msg.source
    if source == '>>>' then
        local color
        source, color = draw.outbound(msg)
        color(win)
    elseif source then
        local head, kind = string.match(source, '^(.-)([.!])')
        source = head or source
        if kind == '!' then
            draw.cyan(win)
        else
            draw.yellow(win)
        end
    end
    ctx.add_button(win, string.format(' %16.16s', scrub(source or '')), inspect, plain)
    draw.normal(win)
    win:waddstr ' '
end

local function render_msg(ctx, win, net, msg)
    local function inspect()
        control.open_detail('message', net, msg)
    end
    -- the inspected message shows its sender as a button would
    local detail = control.detail()
    local plain = not (detail and detail.data == msg)

    source_button(ctx, win, msg, inspect, plain)

    local snote_text = message.snotice_text(net, msg)
    if snote_text ~= nil then
        draw.magenta(win)
        draw.bold(win)
        win:waddstr 'SNOW '
        draw.bold_(win)
        draw.cyan(win)
        win:waddstr ':'
        draw.normal(win)
        addircstr(win, snote_text:sub(1, 400))
        return
    end

    local color = message.color(net, msg.command)
    if color then color(win) end
    draw.bold(win)
    win:waddstr(string.format('%4.4s', msg.command))
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

local squelch_commands <const> = {
    PONG = true,
    PING = true,
    AWAY = true,
}

-- What Meta-H hides: notices to *, and server notices however their
-- server sends them (OFTC hybrid's go to our nick)
local function snow(net, msg)
    return msg.command == 'NOTICE' and msg[1] == '*'
        or message.snotice_text(net, msg) ~= nil
        or squelch_commands[msg.command] ~= nil
end

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
    [meta 'g'] = function(ctx)
        ctx.vs.all = not ctx.vs.all
        ctx.vs.scroll = 0
    end,
}

return {
    id = 'console',
    title = 'console',
    scope = 'net',

    modes = function(ctx)
        local vs = ctx.vs
        local modes = {}
        if vs.hide_snow then table.insert(modes, 'hide') end
        if vs.all then table.insert(modes, 'all') end
        return modes
    end,

    render = function(ctx, win)
        local data = console_of(ctx)
        if not data then
            win:waddstr 'No network selected\n'
            return
        end

        -- a message to bring into view clears what could hide it, and
        -- leaves all networks when that ring no longer holds it
        local reveal = ctx.vs.reveal
        if reveal then
            control.set_filter(ctx.id, nil)
            if snow(ctx.net, reveal) then ctx.vs.hide_snow = nil end
            if ctx.vs.all and not OrderedMap.find(data, function(entry) return entry.msg == reveal end) then
                ctx.vs.all = nil
                data = console_of(ctx)
                ---@cast data -nil the network's ring, as the all ring was there
            end
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
                if all then return not snow(msg.net, msg.msg) end
                return not snow(ctx.net, msg)
            end
        end
        if reveal then
            ctx.vs.reveal = nil
            draw.scroll_to(ctx.vs, ctx.rows, data, show, function(entry)
                return (all and entry.msg or entry) == reveal
            end)
        end

        draw.draw_rotation(win, ctx.vs, 0, ctx.rows, data, show, function(w, entry)
            local net = ctx.net
            if all then
                draw.bold(w)
                w:waddstr(string.format(' %-8.8s', entry.net))
                draw.normal(w)
                net, entry = entry.net, entry.msg
            end
            render_msg(ctx, w, net, entry)
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
