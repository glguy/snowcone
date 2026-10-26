-- The status log (from ircc/view/status.lua).

local addircstr  <const> = require 'hub.ui.irc_formatting'
local control    <const> = require 'hub.ui.control'
local draw       <const> = require 'hub.ui.draw'
local matching   <const> = require 'hub.lib.matching'

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
}
