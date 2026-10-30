-- The current network: what lasts across connections (server, state,
-- features), then the connection, if any (nick, link, transport, modes,
-- capabilities, channels, tasks).
--
-- Long lists show their first row; click [+N more] for the rest. Caps put
-- the trouble first: red for wanted but not enabled, green for enabled,
-- plain for offered but unused.

local clock  <const> = require 'hub.runtime.clock'
local draw   <const> = require 'hub.ui.draw'
local fields <const> = require 'hub.ui.fields'
local scrub  <const> = require 'hub.lib.scrub'
local tablex <const> = require 'pl.tablex'

local heading <const> = fields.heading
local label   <const> = fields.label
local key     <const> = fields.key
local words   <const> = fields.words

-- as in the networks view
local phase_color <const> = {
    connected = draw.green,
    idle = draw.red,
}

-- A word for fields.words: the name, or a {name, value} pair
local function keyval(k, v)
    if v == true then return scrub(k) end
    return {scrub(k), scrub(tostring(v))}
end

local function keyvals(t)
    local list = {}
    for k, v in tablex.sort(t) do
        table.insert(list, keyval(k, v))
    end
    return list
end

-- Capabilities with their colors, trouble first, then enabled ones
local function caps(irc)
    local rank = {}
    for cap in pairs(irc.caps_available) do
        if irc.caps_enabled[cap] then rank[cap] = 2
        elseif irc.caps_wanted[cap] then rank[cap] = 1
        else rank[cap] = 3 end
    end
    for cap in pairs(irc.caps_wanted) do
        if not irc.caps_enabled[cap] then rank[cap] = 1 end
    end

    local names = tablex.keys(rank)
    table.sort(names, function(a, b)
        if rank[a] ~= rank[b] then return rank[a] < rank[b] end
        return a < b
    end)

    local list, color = {}, {}
    for _, cap in ipairs(names) do
        local v = irc.caps_available[cap]
        table.insert(list, keyval(cap, v == nil and true or v))
        color[scrub(cap)] = rank[cap] == 1 and draw.red or rank[cap] == 2 and draw.green or nil
    end
    return list, function(win, text)
        local f = color[text]
        if f then f(win) end
    end
end

local function render_network(ctx, win, rec, now)
    local cfg = rec.cfg

    heading(win, rec.id)

    label(win, 'server')
    local server = cfg.server
    win:waddstr(server.path and scrub(server.path) or scrub(server.host) .. ':' .. server.port, '\n')

    label(win, 'state')
    local color = phase_color[rec.phase] or draw.yellow
    color(win)
    win:waddstr(rec.phase)
    draw.normal(win)
    win:waddstr(' ', draw.duration(now - rec.since))
    if rec.target ~= rec.phase then
        key(win, 'target')
        win:waddstr(rec.target)
    end
    if rec.target == 'connected' and rec.phase ~= 'connected' then
        key(win, 'attempt')
        win:waddstr(tostring(rec.attempt))
        if rec.reconnect_timer and rec.reconnect_at then
            key(win, 'retry')
            win:waddstr(draw.duration(math.max(0, rec.reconnect_at - now)))
        end
        key(win, 'backoff')
        win:waddstr(string.format('%gs', rec.backoff))
    end
    if rec.restart_pending then
        draw.yellow(win)
        win:waddstr '  restart pending: /reconnect'
        draw.normal(win)
    end
    win:waddstr '\n'

    local features = tablex.keys(cfg.features)
    table.sort(features)
    label(win, 'features')
    words(ctx, win, 'features', features)
end

local function render_connection(ctx, win, rec, now)
    heading(win, 'Connection')

    local irc = rec.irc
    if irc and irc.nick then
        label(win, 'nick')
        draw.bold(win)
        win:waddstr(scrub(irc.nick))
        draw.normal(win)
        local wanted = rec.cfg.identity.nick
        if irc.nick ~= wanted then
            key(win, 'wanted')
            win:waddstr(scrub(wanted))
        end
        key(win, 'account')
        win:waddstr(irc.account and scrub(irc.account) or '-', '\n')
    end

    label(win, 'link')
    key(win, 'lag')
    win:waddstr(rec.lag and string.format('%.3fs', rec.lag) or '-')
    key(win, 'idle')
    win:waddstr(rec.liveness and draw.duration(now - rec.liveness) or '-', '\n')

    label(win, 'transport')
    win:waddstr(scrub(rec.fingerprint or '-'), '\n')

    if not irc then return end

    local modes = tablex.keys(irc.mode)
    table.sort(modes)
    label(win, 'modes')
    win:waddstr(next(modes) and '+' .. table.concat(modes) or '-')
    if irc.snomask then
        key(win, 'snomask')
        win:waddstr(scrub(irc.snomask))
    end
    win:waddstr '\n'

    label(win, 'caps')
    words(ctx, win, 'caps', caps(irc))

    label(win, 'isupport')
    words(ctx, win, 'isupport', keyvals(irc.isupport))

    label(win, 'channels')
    local names = {}
    for _, channel in tablex.sort(irc.channels) do
        table.insert(names, scrub(channel.name))
    end
    words(ctx, win, 'channels', names)

    if irc.monitor then
        label(win, 'monitor')
        local list = {}
        for k, v in tablex.sort(irc.monitor) do
            table.insert(list, (v.user and '+' or '-') .. scrub(v.user and v.user.nick or k))
        end
        words(ctx, win, 'monitor', list, function(w, text)
            if text:sub(1, 1) == '+' then draw.green(w) end
        end)
    end

    label(win, 'tasks')
    local tasks = {}
    for _, t in tablex.sort(HUB.tasks) do
        if t.net == rec.id then table.insert(tasks, scrub(t.name)) end
    end
    words(ctx, win, 'tasks', tasks)
end

return {
    id = 'session',
    title = 'session',
    scope = 'net',
    document = true,

    -- Esc folds the lists again
    reset = function(vs) vs.expanded = nil end,

    render = function(ctx, win)
        local rec = ctx.net and HUB.state.nets[ctx.net]
        if not rec then
            win:waddstr 'No network selected\n'
            return
        end
        local now = clock.now()
        render_network(ctx, win, rec, now)
        if rec.conn then
            render_connection(ctx, win, rec, now)
        end
    end,
}
