-- Command list (from ircc/view/help.lua), with each command's help text.

local draw   <const> = require 'hub.ui.draw'
local scrub  <const> = require 'hub.lib.scrub'
local tablex <const> = require 'pl.tablex'

return {
    id = 'help',
    title = 'help',
    scope = 'global',

    render = function(ctx, win)
        draw.magenta(win)
        draw.bold(win)
        win:waddstr 'Commands'
        draw.normal(win)
        win:waddstr '   (net commands take an optional @network first)\n'

        local width = 1
        for name, cmd in pairs(HUB.current.commands) do
            local n = #name + #cmd.spec + 2
            if n > width then width = n end
        end

        for name, cmd in tablex.sort(HUB.current.commands) do
            draw.bold(win)
            win:waddstr(string.format('/%-' .. width .. 's', name .. ' ' .. cmd.spec))
            draw.bold_(win)
            if cmd.scope == 'net' then
                draw.cyan(win)
                win:waddstr ' net '
                draw.normal(win)
            else
                win:waddstr '     '
            end
            win:waddstr(scrub(cmd.help or ''), '\n')
            if ncurses.getyx(win) >= ctx.rows - 1 then break end
        end
    end,
}
