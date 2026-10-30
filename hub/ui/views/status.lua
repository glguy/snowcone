-- The status log. A line that summarizes something longer, such as a
-- WHOIS, starts with ▸: click it to show it in the detail pane.

local addircstr  <const> = require 'hub.ui.irc_formatting'
local control    <const> = require 'hub.ui.control'
local draw       <const> = require 'hub.ui.draw'
local matching   <const> = require 'hub.lib.matching'

local function draw_entry(ctx, win, entry)
    draw.blue(win)
    win:waddstr(string.format(' %-10.10s ', entry.category or '-'))
    draw.normal(win)
    if entry.net then
        draw.cyan(win)
        win:waddstr(entry.net, ' ')
        draw.normal(win)
    end
    local detail = entry.detail
    local y, x = ncurses.getyx(win)
    if detail then
        draw.yellow(win)
        win:waddstr '▸ '
        draw.normal(win)
    end
    -- a line longer than the pad wraps onto the rows below
    addircstr(win, entry.text:sub(1, 400))
    if detail then
        local y2, x2 = ncurses.getyx(win)
        ctx.add_click(y, x, y2 == y and x2 or ctx.cols, function()
            control.open_detail(detail.kind, entry.net, detail.data)
        end)
    end
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
        draw.draw_rotation(win, ctx.vs, 1, ctx.rows - 1, HUB.state.log, show, function(w, entry)
            draw_entry(ctx, w, entry)
        end)
    end,
}
