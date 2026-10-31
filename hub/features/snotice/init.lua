-- Server notices: recognize them on networks with the
-- snotice feature, parse them, update the stores and emit `snote` and
-- `snote.<name>` with the network id.

local bus      <const> = require 'hub.runtime.bus'
local clock    <const> = require 'hub.runtime.clock'
local common   <const> = require 'hub.features.common'
local lexer    <const> = require 'pl.lexer'
local loadavg  <const> = require 'hub.lib.loadavg'
local log      <const> = require 'hub.runtime.log'
local manager  <const> = require 'hub.net.manager'
local matching <const> = require 'hub.lib.matching'
local N        <const> = require 'hub.lib.numerics'
local nettrack <const> = require 'hub.features.snotice.nettrack'
local parse    <const> = require 'hub.features.snotice.parse'
local send     <const> = require 'hub.net.send'
local stores   <const> = require 'hub.features.snotice.stores'

local M = {}

M.name = 'snotice'

--- Server notice mask set after opering, unless the network configures
--- `snomask`
M.default_snomask = 'BFZbcklnsx'

local header <const> = '*** Notice -- '

--- The text of a server notice, without its header, or nil. A server
--- notice is a NOTICE to * from a server (no ! or @ in the source).
---@param msg hub.Message
---@return string|nil
function M.notice_text(msg)
    local source = msg.source
    if msg.command == 'NOTICE' and msg[1] == '*' and #msg == 2
    and source and not source:find '[!@]'
    and msg[2]:sub(1, #header) == header then
        return msg[2]:sub(#header + 1)
    end
end

--- Parse a message into a notice event for a network, or nil.
function M.parse(net, msg)
    local text = M.notice_text(msg)
    if not text then return nil end
    local ev = parse(msg.source, text)
    if ev then
        ev.net = net
        ev.time = msg.time
        ev.timestamp = msg.timestamp
    end
    return ev
end

local function query(net, ...)
    local ok, err = pcall(send.send, net, ...)
    if not ok then
        log.add_net(net, 'snotice', '%s', err)
    end
end

--- Ask for the user count of every tracked address range.
function M.sync(net)
    for _, tracker in pairs(stores.get(net).net_trackers) do
        for label in pairs(tracker) do
            query(net, 'TESTMASK', '*@' .. label)
        end
    end
end

-- Replies that matter to the notice stores
local replies = {}

-- After opering, ask for the notices we show
replies[N.RPL_YOUREOPER] = function(net)
    local rec = HUB.state.nets[net]
    query(net, 'MODE', rec.irc.nick, '+s', rec.cfg.snomask or M.default_snomask)
end

-- "<client> <local> <remote> <mask> <gecos> :Local/remote clients match"
replies[N.RPL_TESTMASKGECOS] = function(net, msg)
    local loc, rem, mask, gecos = msg[2], msg[3], msg[4], msg[5]
    local total = (math.tointeger(loc) or 0) + (math.tointeger(rem) or 0)
    if gecos == '*' and mask and mask:sub(1, 4) == '*!*@' then
        nettrack.set(stores.get(net).net_trackers, mask:sub(5), total)
    end
end

local function on_message(ev)
    if not common.enabled(ev.net, M.name) then return end
    local note = M.parse(ev.net, ev.msg)
    if note then
        stores.apply(note)
        bus.emit('snote', note)
        bus.emit('snote.' .. note.name, note)
        if note.name == 'netjoin' or note.name == 'netsplit' then
            M.sync(note.net)
        end
        return
    end
    local h = replies[ev.msg.command]
    if h then h(ev.net, ev.msg) end
end

-- Every known server gets a row in the load views, traffic or not
local function track_servers(net, names)
    local S = stores.get(net)
    for name in pairs(names) do
        loadavg.track(S.trackers.conn, name, 0)
        loadavg.track(S.trackers.exit, name, 0)
    end
end

-- The servers file's servers, and its address ranges to count. Ranges
-- added while opered are counted now; otherwise opering counts them.
local function apply_servers(net)
    local servers = common.servers(net)
    ---@cast servers -nil snotice is enabled, so the network exists
    track_servers(net, servers.servers)
    local S = stores.get(net)
    local irc = HUB.state.nets[net].irc
    local opered = irc and irc.oper
    for name, ranges in pairs(servers.net_tracks or {}) do
        if not S.net_trackers[name] then
            for _, range in ipairs(ranges) do
                local ok, err = pcall(nettrack.add, S.net_trackers, name, range)
                if not ok then
                    log.add_net(net, 'snotice', 'net_tracks %s: %s', name, err)
                elseif opered then
                    query(net, 'TESTMASK', '*@' .. range)
                end
            end
        end
    end
end

function M.subscribe(sub)
    sub.on('irc.message', on_message)
    sub.on('topology.map', function(ev)
        if common.enabled(ev.net, M.name) then track_servers(ev.net, ev.population) end
    end)
    sub.on('irc.oper', function(ev)
        if common.enabled(ev.net, M.name) then M.sync(ev.net) end
    end)
    sub.on('clock.tick', stores.tick)
    sub.on('net.removed', function(ev) common.drop_state(M.name, ev.net) end)
end

-- Watches from configuration ========================================

--- Make each network's configured watches current: configured ones are
--- replaced (keeping hit counts by pattern), /addwatch ones stay.
function M.apply_watches()
    for _, id in ipairs(manager.ids()) do
        if common.enabled(id, M.name) then
            local S = stores.get(id)
            local hits = {}
            local kept = {}
            for _, watch in ipairs(S.watches) do
                if watch.from_config then
                    hits[watch.pattern] = watch.hits
                else
                    table.insert(kept, watch)
                end
            end
            local configured = {}
            for _, w in ipairs(HUB.state.nets[id].cfg.watches or {}) do
                if matching.compile(w.pattern) then
                    table.insert(configured, {
                        pattern = w.pattern,
                        color = w.color,
                        beep = w.beep,
                        flash = w.flash,
                        active = w.active ~= false,
                        hits = hits[w.pattern] or 0,
                        from_config = true,
                    })
                else
                    log.add_net(id, 'config', 'bad watch pattern: %s', w.pattern)
                end
            end
            table.move(kept, 1, #kept, #configured + 1, configured)
            S.watches = configured
        end
    end
end

function M.activate()
    for _, id in ipairs(manager.ids()) do
        if common.enabled(id, M.name) then apply_servers(id) end
    end
    M.apply_watches()
end

-- Commands ============================================================

local colors <const> = {
    black = true, red = true, green = true, yellow = true,
    blue = true, magenta = true, cyan = true, white = true,
}

-- /addwatch [id] ['pattern'|filter] [color] [beep|nobeep] [flash|noflash]
local function addwatch(ctx, args)
    local S = stores.get(ctx.net)
    local watch = {}
    local id
    for kind, token in lexer.scan(args) do
        if kind == 'iden' and token == 'beep' then
            watch.beep = true
        elseif kind == 'iden' and token == 'nobeep' then
            watch.beep = false
        elseif kind == 'iden' and token == 'flash' then
            watch.flash = true
        elseif kind == 'iden' and token == 'noflash' then
            watch.flash = false
        elseif kind == 'iden' and colors[token] then
            watch.color = token
        elseif kind == 'iden' and token == 'filter' then
            -- the cliconn view's filter
            local vs = HUB.state.ui and HUB.state.ui.views.cliconn
            local pattern = vs and vs.filter
            if not pattern or not matching.compile(pattern) then
                error('the cliconn filter is not a valid pattern', 0)
            end
            watch.pattern = pattern
        elseif kind == 'string' then
            if not matching.compile(token) then
                error('bad pattern: ' .. token, 0)
            end
            watch.pattern = token
        elseif kind == 'number' and math.tointeger(token) then
            id = math.tointeger(token)
        else
            error('unexpected token: ' .. tostring(token), 0)
        end
    end

    if id == nil then
        if watch.pattern == nil then
            error('no watch pattern given', 0)
        end
        watch.active = true
        watch.hits = 0
        table.insert(S.watches, watch)
        log.add_net(ctx.net, 'addwatch', 'Added watch #%d', #S.watches)
    else
        local previous = S.watches[id]
        if not previous then
            error('no such watch: ' .. id, 0)
        end
        for k, v in pairs(watch) do previous[k] = v end
        log.add_net(ctx.net, 'addwatch', 'Updated watch #%d', id)
    end
end

M.commands = {
    {
        name = 'addwatch', spec = '$r', scope = 'net', feature = 'snotice',
        usage = "[id] 'pattern'|filter [color] [no]beep [no]flash",
        help = 'Mark and alert on connections',
        fn = addwatch,
    },
    {
        name = 'delwatch', spec = '$i', usage = 'number', scope = 'net', feature = 'snotice',
        help = 'Remove a watch by number',
        fn = function(ctx, i)
            local watches = stores.get(ctx.net).watches
            if not watches[i] then
                error('no such watch: ' .. tostring(i), 0)
            end
            table.remove(watches, i)
        end,
    },
    {
        name = 'nettrack', spec = '$g $g', usage = 'name address[/prefix]', scope = 'net', feature = 'snotice',
        help = 'Count users in an address range',
        fn = function(ctx, name, range)
            nettrack.add(stores.get(ctx.net).net_trackers, name, range)
            local irc = HUB.state.nets[ctx.net].irc
            if irc and irc.oper then
                query(ctx.net, 'TESTMASK', '*@' .. range)
            end
        end,
    },
    {
        name = 'inject', spec = '$r', usage = 'notice', scope = 'net', feature = 'snotice',
        help = 'Handle a server notice as if a server sent it (for testing)',
        fn = function(ctx, text)
            local note = parse('INJECT.', text)
            if not note then
                error('no notice format matches', 0)
            end
            note.net = ctx.net
            note.time = os.date '!%H:%M:%S'
            note.timestamp = clock.now()
            stores.apply(note)
            bus.emit('snote', note)
            bus.emit('snote.' .. note.name, note)
        end,
    },
}

return M
