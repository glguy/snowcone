-- Raw IRC traffic of the current network.
--
-- Click a command to inspect the message in the detail pane
-- (ui/details/message.lua). Meta-H hides server notices and
-- PING/PONG/AWAY; Meta-G switches between the current network and all
-- networks interleaved, with a network column.
-- View state: scroll, hscroll, filter, hide_snow, all.

local addircstr     <const> = require 'hub.ui.irc_formatting'
local control       <const> = require 'hub.ui.control'
local draw          <const> = require 'hub.ui.draw'
local matching      <const> = require 'hub.lib.matching'
local message       <const> = require 'hub.ui.details.message'
local scrub         <const> = require 'hub.lib.scrub'

local meta <const> = function(x) return -string.byte(x) end

local palette <const> = message.palette

local function pretty_source(win, source, msg)
    if source == '>>>' then
        local color
        source, color = draw.outbound(msg)
        color(win)
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

local function render_msg(ctx, win, net, msg)
    local function inspect()
        control.open_detail('message', net, msg)
    end
    -- the inspected message shows its command as a button would
    local detail = control.detail()
    local plain = not (detail and detail.data == msg)

    local snote_text = message.snotice_text(msg)
    if snote_text ~= nil then
        pretty_source(win, msg.source, msg)
        draw.magenta(win)
        draw.bold(win)
        ctx.add_button(win, 'SNOW ', inspect, plain)
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
    ctx.add_button(win, string.format('%4.4s', msg.command), inspect, plain)
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
