-- Networks of a soju bouncer.

local draw   <const> = require 'hub.ui.draw'
local scrub  <const> = require 'hub.lib.scrub'
local tablex <const> = require 'pl.tablex'

return {
    id = 'bouncer',
    title = 'bouncer',
    scope = 'net',

    render = function(ctx, win)
        draw.green(win)
        win:waddstr '          -= bouncer-networks =-\n'
        draw.normal(win)

        local rec = ctx.net and HUB.state.nets[ctx.net]
        local networks = rec and rec.irc and rec.irc.bouncer_networks
        if not networks then
            win:waddstr 'no bouncer networks'
            return
        end
        for netid, attrs in tablex.sort(networks) do
            draw.green(win)
            win:waddstr(string.format('%5s', scrub(netid)))
            draw.normal(win)
            for key, val in tablex.sort(attrs) do
                if key ~= 'error' then
                    draw.blue(win)
                    win:waddstr(string.format(' %s: ', scrub(key)))
                    draw.normal(win)
                    win:waddstr(scrub(tostring(val)))
                end
            end
            win:waddstr '\n'
            if attrs.error then
                draw.blue(win)
                win:waddstr '      error: '
                draw.normal(win)
                win:waddstr(scrub(attrs.error), '\n')
            end
        end
    end,
}
