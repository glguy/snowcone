-- The current network: what lasts across connections (configuration in
-- effect, state, attempts and backoff, features), then the connection, if
-- any (link, transport, nick, modes, capabilities, channels, tasks). The
-- connection part comes from ircc/view/session.lua.

local clock  <const> = require 'hub.runtime.clock'
local draw   <const> = require 'hub.ui.draw'
local scrub  <const> = require 'hub.lib.scrub'
local tablex <const> = require 'pl.tablex'

local function section(win, text)
    draw.green(win)
    draw.bold(win)
    win:waddstr(text, '\n')
    draw.normal(win)
end

local function label(win, txt)
    win:waddstr(string.format('%14s: ', txt))
end

-- Write words, wrapping under the value column
local function words(ctx, win, list, colour_of)
    for _, text in ipairs(list) do
        local _, x = ncurses.getyx(win)
        if x + #text > ctx.cols then
            win:waddstr '\n                '
        end
        if colour_of then colour_of(win, text) end
        win:waddstr(text, ' ')
    end
    draw.normal(win)
    win:waddstr '\n'
end

local function keyvals(t)
    local list = {}
    for k, v in tablex.sort(t) do
        local text = scrub(k)
        if v ~= true then
            text = text .. '=' .. scrub(tostring(v))
        end
        table.insert(list, text)
    end
    return list
end

return {
    id = 'session',
    title = 'session',
    scope = 'net',

    render = function(ctx, win)
        local rec = ctx.net and HUB.state.nets[ctx.net]
        if not rec then
            win:waddstr 'No network selected\n'
            return
        end
        local cfg = rec.cfg
        local now = clock.now()

        -- what lasts across connections
        section(win, 'Network')

        label(win, 'Network')
        draw.bold(win)
        win:waddstr(rec.id)
        draw.normal(win)
        win:waddstr(string.format('  %s:%s', scrub(cfg.server.host or '?'), tostring(cfg.server.port or '?')))
        if cfg.identity then
            win:waddstr('  as ', scrub(cfg.identity.nick))
        end
        win:waddstr '\n'

        label(win, 'State')
        win:waddstr(string.format('%s for %s, target %s, attempt %d',
            rec.phase, draw.duration(now - rec.since), rec.target, rec.attempt))
        if rec.reconnect_timer and rec.reconnect_at then
            win:waddstr(string.format(', retry in %s', draw.duration(math.max(0, rec.reconnect_at - now))))
        end
        win:waddstr(string.format(', backoff %gs', rec.backoff))
        if rec.restart_pending then
            draw.yellow(win)
            win:waddstr '  restart pending: /reconnect'
            draw.normal(win)
        end
        win:waddstr '\n'

        local features = {}
        for name in pairs(cfg.features) do table.insert(features, name) end
        table.sort(features)
        label(win, 'Features')
        win:waddstr(table.concat(features, ' '), '\n')

        -- this connection
        section(win, 'Connection')
        if not rec.conn then
            win:waddstr 'not connected\n'
            return
        end

        label(win, 'Link')
        win:waddstr(string.format('lag %s, idle %s',
            rec.lag and string.format('%.3fs', rec.lag) or '?',
            rec.liveness and draw.duration(now - rec.liveness) or '?'))
        if rec.registered_at then
            win:waddstr(', registered ', draw.duration(now - rec.registered_at), ' ago')
        end
        win:waddstr '\n'

        if rec.fingerprint then
            label(win, 'Transport')
            win:waddstr(scrub(rec.fingerprint), '\n')
        end

        local irc = rec.irc
        if not irc then return end

        if irc.nick then
            label(win, 'Nick')
            draw.bold(win)
            win:waddstr(scrub(irc.nick))
            draw.normal(win)
            if irc.account then
                win:waddstr('  account ', scrub(irc.account))
            end
            win:waddstr '\n'
        end

        label(win, 'Mode')
        win:waddstr(table.concat(tablex.keys(irc.mode)), '\n')

        if irc.snomask then
            label(win, 'Snomask')
            win:waddstr(scrub(irc.snomask), '\n')
        end

        label(win, 'Casemapping')
        win:waddstr(irc.casemapping, '\n')

        label(win, 'Isupport')
        words(ctx, win, keyvals(irc.isupport))

        label(win, 'Caps')
        words(ctx, win, keyvals(irc.caps_available), function(w, text)
            local name = text:match '^[^=]*'
            if irc.caps_enabled[name] then draw.green(w) else draw.red(w) end
        end)

        label(win, 'Channels')
        local names = {}
        for _, channel in tablex.sort(irc.channels) do
            table.insert(names, scrub(channel.name))
        end
        words(ctx, win, names)

        if irc.monitor then
            label(win, 'Monitor')
            local list = {}
            for k, v in tablex.sort(irc.monitor) do
                table.insert(list, (v.user and '+' or '-') .. scrub(v.user and v.user.nick or k))
            end
            words(ctx, win, list)
        end

        label(win, 'Tasks')
        local tasks = {}
        for _, t in tablex.sort(HUB.tasks) do
            if t.net == rec.id then table.insert(tasks, t.name) end
        end
        words(ctx, win, tasks)
    end,
}
