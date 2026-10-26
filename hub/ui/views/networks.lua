-- Every network at a glance, in configuration order.
-- Click a name to open that network's page (/session). "retry" counts down to a
-- scheduled reconnect.

local clock   <const> = require 'hub.runtime.clock'
local control <const> = require 'hub.ui.control'
local draw    <const> = require 'hub.ui.draw'
local scrub   <const> = require 'hub.lib.scrub'

local phase_colour <const> = {
    connected = draw.green,
    idle = draw.red,
}

return {
    id = 'networks',
    title = 'networks',
    scope = 'global',

    render = function(ctx, win)
        local current = control.current_net()
        local now = clock.now()

        draw.magenta(win)
        draw.bold(win)
        win:waddstr(string.format('  %-16s %-18s %6s %7s %5s %7s %-16s %s\n',
            'network', 'phase', 'for', 'attempt', 'retry', 'lag', 'nick', 'transport'))
        draw.normal(win)

        for _, id in ipairs(control.net_ids()) do
            local rec = HUB.state.nets[id]
            win:waddstr(id == current and '▶ ' or '  ')
            draw.bold(win)
            ctx.add_button(win, string.format('%-16.16s', id), function()
                control.set_current_net(id)
                control.set_view 'session'
            end, true)
            draw.normal(win)
            win:waddstr ' '

            local colour = phase_colour[rec.phase] or draw.yellow
            colour(win)
            local phase = rec.phase
            if rec.target ~= 'connected' and rec.target ~= rec.phase then
                phase = phase .. '→' .. rec.target
            end
            win:waddstr(string.format('%-18.18s', phase))
            draw.normal(win)

            local retry = '-'
            if rec.reconnect_timer and rec.reconnect_at then
                retry = string.format('%.0fs', math.max(0, rec.reconnect_at - now))
            end
            local irc = rec.irc
            win:waddstr(string.format(' %6s %7d %5s %7s %-16.16s %s',
                draw.duration(now - rec.since),
                rec.attempt,
                retry,
                rec.lag and string.format('%.3f', rec.lag) or '-',
                irc and irc.nick and scrub(irc.nick) or '-',
                scrub(rec.fingerprint or '-')))

            if rec.restart_pending then
                draw.yellow(win)
                win:waddstr '  restart pending: /reconnect'
                draw.normal(win)
            end
            win:waddstr '\n'
        end
    end,
}
