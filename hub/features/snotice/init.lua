-- Server notices: recognize them on networks with the
-- snotice feature, parse them, update the stores and emit `snote` and
-- `snote.<name>` with the network id.

local bus      <const> = require 'hub.runtime.bus'
local common   <const> = require 'hub.features.common'
local config_schema <const> = require 'hub.runtime.config_schema'
local ircd     <const> = require 'hub.net.ircd'
local loadavg  <const> = require 'hub.lib.loadavg'
local log      <const> = require 'hub.runtime.log'
local manager  <const> = require 'hub.net.manager'
local matching <const> = require 'hub.lib.matching'
local N        <const> = require 'hub.lib.numerics'
local NH       <const> = require 'hub.lib.numerics_hybrid'
local nettrack <const> = require 'hub.features.snotice.nettrack'
local notice   <const> = require 'hub.features.snotice.notice'
local stores   <const> = require 'hub.features.snotice.stores'

local M = {}

local query <const> = common.sender 'snotice'

M.name = 'snotice'

--- What chooses the notices we see after opering, by ircd, unless the
--- network configures `snomask`: Solanum's server notice mask, and the
--- user modes OFTC hybrid sends notices by.
M.default_snomask = {
    [ircd.SOLANUM] = 'BFZbcklnsx',
    [ircd.HYBRID] = 'bcfknrs',
}

--- Parse a message into a notice event for a network, or nil.
function M.parse(net, msg)
    local ev = notice.parse(net, msg)
    if ev then
        ev.net = net
        ev.time = msg.time
        ev.timestamp = msg.timestamp
    end
    return ev
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
    local ircd_name = ircd.of(net)
    local modes = rec.cfg.snomask or M.default_snomask[ircd_name]
    if ircd_name == ircd.HYBRID then
        query(net, 'MODE', rec.irc.nick, '+' .. modes:gsub('^%+', ''))
    else
        query(net, 'MODE', rec.irc.nick, '+s', modes)
    end
end

--- The users a TESTMASK reply counts, and the user@host mask it counted,
--- or nil for another reply. Solanum's has a nick and a realname too:
--- "<client> <local> <remote> <nick>!<user@host> <realname> :..." where
--- hybrid's is "<client> <user@host> <local> <remote> :...".
---@param net string
---@param msg hub.Message
---@return integer|nil, string|nil
function M.testmask_count(net, msg)
    local loc, rem, mask
    if ircd.hybrid(net) then
        if msg.command ~= NH.RPL_TESTMASK then return nil end
        mask, loc, rem = msg[2], msg[3], msg[4]
    else
        if msg.command ~= N.RPL_TESTMASKGECOS or msg[5] ~= '*' then return nil end
        loc, rem = msg[2], msg[3]
        mask = msg[4] and msg[4]:match '^%*!(.*)$'
    end
    if not mask then return nil end
    return (math.tointeger(loc) or 0) + (math.tointeger(rem) or 0), mask
end

--- The numeric of a network's TESTMASK count.
function M.testmask_numeric(net)
    return ircd.hybrid(net) and NH.RPL_TESTMASK or N.RPL_TESTMASKGECOS
end

local function testmask_reply(net, msg)
    local total, mask = M.testmask_count(net, msg)
    if not total then return end
    ---@cast mask -nil a count comes with the mask it counted
    if mask:sub(1, 2) == '*@' then
        nettrack.set(stores.get(net).net_trackers, mask:sub(3), total)
    end
end
replies[N.RPL_TESTMASKGECOS] = testmask_reply
replies[NH.RPL_TESTMASK] = testmask_reply

local function on_message(ev)
    -- every network's, so the console shows its notices as notices
    notice.record(ev.net, ev.msg)
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

-- The servers file's servers, and its address ranges to count, made to
-- match the file: trackers it no longer names go, ranges it dropped go,
-- and ranges it keeps keep their counts. A tracker from the file replaces
-- one /nettrack made with its name. Ranges added while opered are
-- counted now; otherwise opering counts them.
local function apply_servers(net)
    local servers = common.servers(net)
    ---@cast servers -nil snotice is enabled, so the network exists
    track_servers(net, servers.servers)
    local S = stores.get(net)
    local irc = HUB.state.nets[net].irc
    local opered = irc and irc.oper
    local wanted = servers.net_tracks or {}

    -- the trackers the file made last time
    local previous = S.file_tracks or {}
    for name in pairs(previous) do
        if not wanted[name] then S.net_trackers[name] = nil end
    end
    S.file_tracks = {}
    for name, ranges in pairs(wanted) do
        S.file_tracks[name] = true
        local old = previous[name] and S.net_trackers[name] or {}
        local tracker = {}
        S.net_trackers[name] = tracker
        for _, label in ipairs(ranges) do
            if old[label] then
                tracker[label] = old[label]
            else
                local ok, err = pcall(nettrack.add, S.net_trackers, name, label)
                if not ok then
                    log.add_net(net, 'snotice', 'net_tracks %s: %s', name, err)
                elseif opered then
                    query(net, 'TESTMASK', '*@' .. label)
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
    sub.on('irc.isupport', function(ev)
        if ev.key == 'CASEMAPPING' and common.enabled(ev.net, M.name) then
            stores.set_casemapping(ev.net, HUB.state.nets[ev.net].irc.casemapping)
        end
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

local colors <const> = config_schema.colors

-- A watch's options as typed: each a quoted pattern, its escapes kept
-- for the pattern, or a run of anything but spaces and quotes. Each is
-- {lo, hi, word} or {lo, hi, pattern, closed}, by byte.
local function watch_words(args)
    local words, pos = {}, 1
    while true do
        local lo = args:match('^ *()', pos)
        if lo > #args then break end
        local quote = args:sub(lo, lo)
        if quote == "'" or quote == '"' then
            local i = lo + 1
            while i <= #args and args:sub(i, i) ~= quote do
                i = i + (args:sub(i, i) == '\\' and 2 or 1)
            end
            local closed = i <= #args
            local hi = math.min(i, #args)
            local pattern = args:sub(lo + 1, closed and hi - 1 or hi)
            table.insert(words, {lo = lo, hi = hi, pattern = pattern, closed = closed})
        else
            local hi = (args:find('[ \'"]', lo) or #args + 1) - 1
            table.insert(words, {lo = lo, hi = hi, word = args:sub(lo, hi)})
        end
        pos = words[#words].hi + 1
    end
    return words
end

-- What one option sets: the field and its value, or nil and why not.
-- filter takes the cliconn view's filter.
local switches <const> = {
    beep = {'beep', true}, nobeep = {'beep', false},
    flash = {'flash', true}, noflash = {'flash', false},
}
local function watch_option(ctx, w)
    if w.pattern then
        if not w.closed then return nil, 'unclosed quote: ' .. w.pattern end
        if not matching.compile(w.pattern) then return nil, 'bad pattern: ' .. w.pattern end
        return 'pattern', w.pattern
    elseif w.word == 'filter' then
        local pattern = ctx.filter
        if not pattern or not matching.compile(pattern) then
            return nil, 'the cliconn filter is not a valid pattern'
        end
        return 'pattern', pattern
    elseif switches[w.word] then
        return table.unpack(switches[w.word])
    elseif colors[w.word] then
        return 'color', w.word
    end
    return nil, 'unexpected token: ' .. w.word
end

-- A watch's options, in any order: 'pattern' or filter, a color, [no]beep
-- and [no]flash; a later one setting what an earlier did wins
local function watch_options(ctx, args)
    local watch = {}
    for _, w in ipairs(watch_words(args)) do
        local field, value = watch_option(ctx, w)
        if field == nil then error(value, 0) end
        watch[field] = value
    end
    return watch
end

-- What each placeholder of /addwatch and /editwatch stands for
local placeholder_fields <const> = {
    ["'pattern'|filter"] = 'pattern', color = 'color', ['[no]beep'] = 'beep', ['[no]flash'] = 'flash',
}

-- The watch a number (read as $i reads one) names on a network with
-- the feature, if any
local function numbered_watch(net, word)
    if not (net and common.enabled(net, M.name) and word and word:match '^[+-]?%d+$') then return nil end
    local i = math.tointeger(tonumber(word))
    return i and stores.get(net).watches[i]
end

-- A watch's settings, as the options that would set them, by placeholder
local function watch_settings(watch)
    local function switch(value, name)
        if value == nil then return nil end
        return value and name or 'no' .. name
    end
    -- in the quotes that can be typed around it
    local quote = watch.pattern:find("'", 1, true) and not watch.pattern:find('"', 1, true) and '"' or "'"
    return {
        ["'pattern'|filter"] = quote .. watch.pattern .. quote,
        color = watch.color,
        ['[no]beep'] = switch(watch.beep, 'beep'),
        ['[no]flash'] = switch(watch.flash, 'flash'),
    }
end

-- The options as the input line shows them, read as the command reads
-- them: red when one isn't an option, which a pattern or filter stays
-- however the line goes on. Still to come, the options not yet given:
-- for a watch being edited, as it has them now.
local function watch_shape(ctx, rest, slot, before)
    local words, given = {}, {}
    for _, w in ipairs(watch_words(rest)) do
        local field = watch_option(ctx, w)
        if field then given[field] = true end
        local final = w.pattern and w.closed or w.word == 'filter'
        table.insert(words, {lo = w.lo, hi = w.hi, ok = field ~= nil, final = final})
    end
    local watch = numbered_watch(ctx.net, before[1])
    local now = watch and watch_settings(watch) or {}
    local ghosts = {}
    for _, p in ipairs(slot) do
        if not given[placeholder_fields[p.label]] then
            local setting = now[p.label]
            table.insert(ghosts, setting and {label = setting, optional = p.optional, repeats = false} or p)
        end
    end
    return {words = words, ghosts = ghosts}
end

local function addwatch(ctx, args)
    local S = stores.get(ctx.net)
    local watch = watch_options(ctx, args)
    if watch.pattern == nil then
        error('no watch pattern given', 0)
    end
    watch.active = true
    watch.hits = 0
    table.insert(S.watches, watch)
    log.add_net(ctx.net, 'addwatch', 'Added watch #%d', #S.watches)
end

-- A watch number names one of the network's watches
local function watch_exists(ctx, i, word)
    return i ~= 1 or numbered_watch(ctx.net, word) ~= nil
end

local function editwatch(ctx, id, args)
    local previous = stores.get(ctx.net).watches[id]
    if not previous then
        error('no such watch: ' .. id, 0)
    end
    -- none changes nothing: the input line showed how it is
    local watch = watch_options(ctx, args)
    if next(watch) == nil then return end
    for k, v in pairs(watch) do previous[k] = v end
    log.add_net(ctx.net, 'editwatch', 'Updated watch #%d', id)
end

M.commands = {
    {
        name = 'addwatch', spec = '$r', scope = 'net', feature = 'snotice',
        usage = "'pattern'|filter [color] [[no]beep] [[no]flash]",
        help = 'Mark and alert on connections; the options in any order',
        fn = addwatch,
        shape = watch_shape,
    },
    {
        name = 'editwatch', spec = '$i $R', scope = 'net', feature = 'snotice',
        usage = "number ['pattern'|filter] [color] [[no]beep] [[no]flash]",
        help = 'Change a watch by number; the options in any order',
        fn = editwatch,
        shape = watch_shape,
        exists = watch_exists,
    },
    {
        name = 'delwatch', spec = '$i', usage = 'number', scope = 'net', feature = 'snotice',
        help = 'Remove a watch by number',
        exists = watch_exists,
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
}

return M
