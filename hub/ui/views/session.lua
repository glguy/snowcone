-- The current network: what lasts across connections (server, state,
-- features), then the connection, if any (nick, link, transport, modes,
-- capabilities, channels, tasks), and behind a soju bouncer, the
-- bouncer's networks (soju.im/bouncer-networks): which one this connection
-- is bound to (ISUPPORT BOUNCER_NETID), if any, then a row each by its id,
-- with its name, state, address (cleartext in yellow), nick and any other
-- attribute but the password, and its error under it. The bouncer sends
-- them only with soju.im/bouncer-networks-notify, which the section says
-- when it isn't enabled.
--
-- Long lists show their first row; click [+N more] for the rest. Caps put
-- the trouble first: red for wanted but not enabled, green for enabled,
-- plain for offered but unused.

local clock  <const> = require 'hub.runtime.clock'
local draw   <const> = require 'hub.ui.draw'
local fields <const> = require 'hub.ui.fields'
local own_nick <const> = require 'hub.net.nick'
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
    -- why a network that is down is down
    if rec.closed and rec.phase ~= 'connected' then
        label(win, 'ended')
        draw.red(win)
        win:waddstr(scrub(rec.closed.text))
        draw.normal(win)
        win:waddstr(' ', draw.duration(now - rec.closed.at), ' ago\n')
    end

    local features = tablex.keys(cfg.features)
    table.sort(features)
    label(win, 'features')
    words(ctx, win, 'features', features)
end

local bouncer_state_color <const> = {
    connected = draw.green,
    connecting = draw.yellow,
    disconnected = draw.red,
}

-- The attributes a bouncer network's row shows in their own places, or not
local placed <const> = {name = true, state = true, host = true, port = true, tls = true, nickname = true,
    error = true, pass = true}

-- The network this connection is bound to, by its id; nil when none
---@param irc hub.Irc
---@return string|nil
local function bound_netid(irc)
    local netid = irc.isupport.BOUNCER_NETID
    if type(netid) == 'string' and netid ~= '' then return netid end
end

---@param irc hub.Irc
local function render_bouncer(win, irc)
    heading(win, 'Bouncer networks')
    local networks, bound = irc.bouncer_networks, bound_netid(irc)

    label(win, 'bound')
    if bound then
        local network = networks and networks[bound]
        draw.bold(win)
        win:waddstr(scrub(network and network.name or bound))
        draw.normal(win)
        if network and network.name then
            key(win, 'id')
            win:waddstr(scrub(bound))
        end
        win:waddstr '\n'
    else
        win:waddstr 'none: this connection reaches only the bouncer\n'
    end

    if not networks then
        label(win, 'networks')
        draw.yellow(win)
        if irc.caps_enabled['soju.im/bouncer-networks-notify'] then
            win:waddstr 'not sent yet\n'
        else
            win:waddstr 'not sent: soju.im/bouncer-networks-notify is not enabled\n'
        end
        draw.normal(win)
        return
    end
    if next(networks) == nil then
        label(win, 'networks')
        win:waddstr '-\n'
        return
    end
    for netid, attrs in tablex.sort(networks) do
        label(win, scrub(netid))
        draw.bold(win)
        win:waddstr(scrub(attrs.name or '-'))
        draw.normal(win)
        if netid == bound then
            draw.green(win)
            win:waddstr '  (this connection)'
            draw.normal(win)
        end
        if attrs.state then
            key(win, 'state')
            local color = bouncer_state_color[attrs.state]
            if color then color(win) end
            win:waddstr(scrub(attrs.state))
            draw.normal(win)
        end
        if attrs.host then
            key(win, 'host')
            win:waddstr(scrub(attrs.host), attrs.port and ':' .. scrub(attrs.port) or '')
            if attrs.tls == '1' then
                win:waddstr ' tls'
            elseif attrs.tls == '0' then
                draw.yellow(win)
                win:waddstr ' cleartext'
                draw.normal(win)
            end
        end
        if attrs.nickname then
            key(win, 'nick')
            win:waddstr(scrub(attrs.nickname))
        end
        for k, v in tablex.sort(attrs) do
            if not placed[k] then
                key(win, scrub(k))
                win:waddstr(scrub(v))
            end
        end
        win:waddstr '\n'
        if attrs.error then
            label(win, 'error')
            draw.red(win)
            win:waddstr(scrub(attrs.error))
            draw.normal(win)
            win:waddstr '\n'
        end
    end
end

local function render_connection(ctx, win, rec, now)
    heading(win, 'Connection')

    local irc = rec.irc
    if irc and irc.nick then
        label(win, 'nick')
        draw.bold(win)
        win:waddstr(scrub(irc.nick))
        draw.normal(win)
        local wanted = own_nick.wanted(rec)
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
    win:waddstr(scrub(rec.step or rec.transport or '-'), '\n')

    if not irc then return end

    local modes = tablex.keys(irc.mode)
    table.sort(modes)
    label(win, 'modes')
    win:waddstr(next(modes) and scrub('+' .. table.concat(modes)) or '-')
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
            local irc = rec.irc
            if irc and (irc.bouncer_networks or irc.caps_enabled['soju.im/bouncer-networks']) then
                render_bouncer(win, irc)
            end
        end
    end,
}
