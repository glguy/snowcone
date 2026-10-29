-- Command list, with each command's help text.

local cmdline   <const> = require 'hub.ui.cmdline'
local draw      <const> = require 'hub.ui.draw'
local scrub     <const> = require 'hub.lib.scrub'
local tablex    <const> = require 'pl.tablex'

return {
    id = 'help',
    keypress = function(ctx, key)
        if key == -string.byte 'a' then
            ctx.vs.all = not ctx.vs.all
            return true
        end
    end,

    modes = function(ctx)
        return {ctx.vs.all and 'all' or nil}
    end,

    title = 'help',
    scope = 'global',
    document = true,

    render = function(ctx, win)
        draw.magenta(win)
        draw.bold(win)
        win:waddstr 'Commands'
        draw.normal(win)
        win:waddstr '   (net commands take an optional @network first; Meta-A: all features)\n'

        local width = 1
        for name, cmd in pairs(HUB.current.commands) do
            local n = #name + #cmd.spec + 2
            if n > width then width = n end
        end

        for name, cmd in tablex.sort(HUB.current.commands) do
            if not cmdline.available(cmd) and not ctx.vs.all then goto continue end
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
            ::continue::
        end
    end,
}
