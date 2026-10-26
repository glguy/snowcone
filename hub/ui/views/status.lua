-- The status log (from ircc/view/status.lua).

local addircstr  <const> = require 'hub.ui.irc_formatting'
local control    <const> = require 'hub.ui.control'
local draw       <const> = require 'hub.ui.draw'
local matching   <const> = require 'hub.lib.matching'
local OrderedMap <const> = require 'hub.lib.OrderedMap'

local function clamp_scroll(ctx, scroll)
    local elts = OrderedMap.size(HUB.state.log)
    scroll = math.min(scroll, elts - ctx.rows + 1)
    return math.max(scroll, 0)
end

local keys = {
    [-ncurses.KEY_PPAGE] = function(ctx)
        ctx.vs.scroll = clamp_scroll(ctx, ctx.vs.scroll + math.max(1, ctx.rows - 1))
    end,
    [-ncurses.KEY_NPAGE] = function(ctx)
        ctx.vs.scroll = math.max(ctx.vs.scroll - math.max(1, ctx.rows - 1), 0)
    end,
    [-ncurses.KEY_UP] = function(ctx)
        ctx.vs.scroll = clamp_scroll(ctx, ctx.vs.scroll + 1)
    end,
    [-ncurses.KEY_DOWN] = function(ctx)
        ctx.vs.scroll = math.max(ctx.vs.scroll - 1, 0)
    end,
}

local function draw_entry(win, entry)
    draw.blue(win)
    win:waddstr(string.format(' %-10.10s ', entry.category or '-'))
    draw.normal(win)
    if entry.net then
        draw.cyan(win)
        win:waddstr(entry.net, ' ')
        draw.normal(win)
    end
    -- a line longer than the pad wraps onto the rows below
    addircstr(win, entry.text:sub(1, 400))
end

return {
    id = 'status',
    title = 'status',
    scope = 'global',

    render = function(ctx, win)
        draw.magenta(win)
        draw.bold(win)
        win:waddstr('time     category   message')
        draw.bold_(win)
        local pattern = control.filter(ctx.id)
        local show
        if pattern then
            show = function(entry)
                return matching.safematch((entry.net or '') .. ' ' .. entry.category .. ' ' .. entry.text, pattern)
            end
        end
        draw.draw_rotation(win, ctx.vs, 1, ctx.rows - 1, HUB.state.log, show, draw_entry)
    end,

    keypress = function(ctx, key)
        local h = keys[key]
        if h then
            h(ctx)
            return true
        end
    end,
}
