local app = require 'pl.app'
local Set = require 'pl.Set'
local tablex = require 'pl.tablex'

local has_mmdb, mmdb = pcall(require, 'mmdb')
if not has_mmdb then mmdb = nil end

require 'pl.stringx'.import()
app.require_here()

local addstr = ncurses.addstr
local mvaddstr = ncurses.mvaddstr
local erase = ncurses.erase
local clear = ncurses.clear
local refresh = ncurses.refresh
local attron = ncurses.attron
local attroff = ncurses.attroff
local attrset = ncurses.attrset

local function normal()     attrset(ncurses.A_NORMAL)     end
local function bold()       attron(ncurses.A_BOLD)        end
local function underline()  attron(ncurses.A_UNDERLINE)   end
local function red()        attron(ncurses.red)           end
local function green()      attron(ncurses.green)         end
local function blue()       attron(ncurses.blue)          end
local function cyan()       attron(ncurses.cyan)          end
local function black()      attron(ncurses.black)         end
local function magenta()    attron(ncurses.magenta)       end
local function yellow()     attron(ncurses.yellow)        end
local function white()      attron(ncurses.white)         end

local palette = {black, red, green, yellow, blue, magenta, cyan, white}

local spinner = {'◴','◷','◶','◵'}

local function require_(name)
    package.loaded[name] = nil
    return require(name)
end

local spam_delay = 6
local primary_hub = 'reynolds.freenode.net'
local server_classes = require_ 'server_classes'
local LoadTracker = require_ 'LoadTracker'
local OrderedMap = require_ 'OrderedMap'
local compute_kline_mask = require_ 'freenode_masks'
local parse_snote = require_ 'parse_snote'

-- Global state =======================================================

function reset_filter()
    filter = nil
    server_filter = nil
    conn_filter = nil
    highlight = nil
    highlight_plain = false
    staged_action = nil
end

local defaults = {
    -- state
    users = OrderedMap(),
    kline_tracker = LoadTracker(),
    conn_tracker = LoadTracker(),
    view = 'connections',
    uptime = 0,
    mrs = {},
    scroll = 0,
    clicon_n = 0,
    filter_tracker = LoadTracker(),
    clicks = {},
    population = {},
    links = {},
    upstream = {},

    -- settings
    history = 1000,
    show_reasons = true,
    kline_duration = 1,
    kline_reason = 1,
    trust_uname = false,
}

function initialize()
    tablex.update(_G, defaults)
    reset_filter()
end

if mmdb and not geoip then
    local success, result = pcall(mmdb.open, 'GeoLite2-ASN.mmdb')
    if success then
        geoip = result
    end
end

if not geoip and not geoip4 then
    -- Other useful edition: mygeoip.GEOIP_ORG_EDITION, GEOIP_ISP_EDITION, GEOIP_ASNUM_EDITION
    local success, result = pcall(mygeoip.open_db, mygeoip.GEOIP_ISP_EDITION)
    if success then
        geoip4 = result
    end
end

if not geoip and not geoip6 then
    local success, result = pcall(mygeoip.open_db, mygeoip.GEOIP_ASNUM_EDITION_V6)
    if success then
        geoip6 = result
    end
end

for k,v in pairs(defaults) do
    if not _G[k] then
        _G[k] = v
    end
end

-- Prepopulate the server list
for k,_ in pairs(server_classes) do
    conn_tracker:track(k..'.freenode.net', 0)
end

-- GeoIP lookup =======================================================

local function ip_org(addr)
    if geoip and string.match(addr, '%.') then
        return geoip:search_ipv4(addr).autonomous_system_organization
    end
    if geoip and string.match(addr, ':') then
        return geoip:search_ipv6(addr).autonomous_system_organization
    end
    if geoip4 and string.match(addr, '%.') then
        return geoip4:get_name_by_addr(addr)
    end
    if geoip6 and string.match(addr, ':') then
        return geoip6:get_name_by_addr_v6(addr)
    end
end


-- Kline logic ========================================================

local kline_durations = {
    {'4h','240'},
    {'1d','1400'},
    {'3d','4320'}
}

local kline_reasons = {
    {'freenodebl', 'Please email kline@freenode.net to request assistance with this ban.|!freenodebl botspam'},
    {'dronebl',    'Please email kline@freenode.net to request assistance with this ban.|!dnsbl'},
    {'broken',     'Your client is repeatedly reconnecting. Please email kline@freenode.net when fixed.'},
    {'plain',      'Please email kline@freenode.net to request assistance with this ban.'},
}

local function entry_to_kline(entry)
    local success, mask = pcall(compute_kline_mask, entry.user, entry.ip, entry.host, entry.gecos, trust_uname)
    if success then
        staged_action = {action='kline', mask=mask, entry=entry}
        send_irc('TESTMASK ' .. mask .. '\r\n')
    else
        last_key = mask
        staged_action = nil
    end
end

local function entry_to_unkline(entry)
    local mask = entry.user .. '@' .. entry.ip
    send_irc('TESTLINE ' .. mask .. '\r\n')
    staged_action = {action = 'unkline', entry = entry}
end

local function kline_ready()
    return view == 'connections' and staged_action ~= nil and staged_action.action == 'kline'
end

local function unkline_ready()
    return view == 'connections'
        and staged_action ~= nil
        and staged_action.action == 'unkline'
        and staged_action.mask ~= nil
end

-- Mouse logic ========================================================

local function add_click(y, lo, hi, action)
    local list = clicks[y]
    local entry = {lo=lo, hi=hi, action=action}
    if list then
        table.insert(list, entry)
    else
        clicks[y] = {entry}
    end
end

local function add_button(text, action)
    local y1,x1 = ncurses.getyx()
    attron(ncurses.A_REVERSE)
    addstr(text)
    attroff(ncurses.A_REVERSE)
    local y2,x2 = ncurses.getyx()
    add_click(y1, x1, x2, action)
end


-- Screen rendering ===================================================

local function draw_load_1(avg, i)
    if avg.n >= 60*i then
        attron(ncurses.A_BOLD)
        addstr(string.format('%.2f  ', avg[i]))
        attroff(ncurses.A_BOLD)
    else
        addstr(string.format('%.2f  ', avg[i]))
    end
end

local function draw_load(avg)
    draw_load_1(avg, 1)
    draw_load_1(avg, 5)
    draw_load_1(avg,15)
    addstr('[')
    underline()
    addstr(avg:graph())
    attroff(ncurses.A_UNDERLINE)
    addstr(']')
end

local function draw_global_load()
    if kline_ready() then red () else white() end
    attron(ncurses.A_REVERSE)
    mvaddstr(tty_height-1, 0, 'sn' .. spinner[uptime % #spinner + 1] .. 'wcone')
    attroff(ncurses.A_REVERSE)
    addstr(' ')
    magenta()
    addstr('CLICON  ')
    draw_load(conn_tracker.global)
    normal()
end

local function show_entry(entry)
    return
    (server_filter == nil or server_filter == entry.server) and
    (conn_filter == nil or conn_filter == entry.connected) and
    (filter      == nil or string.match(entry.mask, filter))
end

local function draw_buttons()
    mvaddstr(tty_height-2, 0, ' ')
    bold()

    black()
    add_button('[ REASON ]', function()
        show_reasons = not show_reasons
    end)
    addstr(' ')

    if filter then
        blue()
        add_button('[ CLEAR FILTER ]', function()
            filter = nil
        end)
        addstr(' ')
    end

    if kline_ready() then
        green()
        add_button('[ CANCEL KLINE ]', function()
            staged_action = nil
            highlight = nil
            highlight_plain = nil
        end)

        addstr(' ')
        cyan()
        add_button('[ ' .. kline_durations[kline_duration][1] .. ' ]', function()
            kline_duration = kline_duration % #kline_durations + 1
        end)

        addstr(' ')
        blue()
        add_button(trust_uname and '[ ~ ]' or '[ = ]', function()
            trust_uname = not trust_uname
            entry_to_kline(staged_action.entry)
        end)

        addstr(' ')
        magenta()
        local blacklist_text =
            string.format('[ %-10s ]', kline_reasons[kline_reason][1])
        add_button(blacklist_text, function()
            kline_reason = kline_reason % #kline_reasons + 1
        end)

        addstr(' ')
        red()
        local klineText = string.format('[ KLINE %s %s %s ]',
            staged_action.count and tostring(staged_action.count) or '?',
            staged_action.entry.nick,
            staged_action.mask)
        add_button(klineText, function()
            send_irc(
                string.format('KLINE %s %s :%s\r\n',
                    kline_durations[kline_duration][2],
                    staged_action.mask,
                    kline_reasons[kline_reason][2]
                )
            )
            staged_action = nil
        end)
    elseif staged_action and staged_action.action == 'unkline' then
        green()
        add_button('[ CANCEL UNKLINE ]', function()
            staged_action = nil
            highlight = nil
            highlight_plain = nil
        end)

        addstr(' ')
        yellow()
        local klineText = string.format('[ UNKLINE %s %s ]',
            staged_action.entry.nick,
            staged_action.mask or '?')
        add_button(klineText, function()
            if staged_action.mask then
                send_irc(
                    string.format('UNKLINE %s\r\n',
                        staged_action.mask
                    )
                )
            end
            staged_action = nil
        end)
    end

    normal()
end

local views = {}

function views.connections()
    local skips = scroll or 0
    local last_time
    local n = 0
    local rotating_view = scroll == 0 and conn_filter == nil

    local rows = math.max(1, tty_height-2)

    for _, entry in users:each() do
        if show_entry(entry) then
            local y
            if rotating_view then
                if n >= rows-1 then break end
                y = (clicon_n-n) % rows
            else
                if n >= rows then break end
                y = rows-n-1
            end

            if skips > 0 then skips = skips - 1 goto skip end

            -- TIME
            local time = entry.time
            local timetxt
            if time == last_time then
                mvaddstr(y, 0, '        ')
            else
                last_time = time
                if uptime - entry.timestamp <= spam_delay then
                    white()
                else
                    cyan()
                end
                mvaddstr(y, 0, time)
                normal()
            end

            local mask_color = entry.connected and ncurses.green or ncurses.red

            if entry.filters then
                attron(mask_color)
                addstr(string.format(' %3d! ', entry.filters))
            else
                if entry.count < 2 then
                    black()
                end
                addstr(string.format(" %4d ", entry.count))
            end
            -- MASK
            if highlight and (
                highlight_plain     and highlight == entry.mask or
                not highlight_plain and string.match(entry.mask, highlight)) then
                    bold()
            end

            attron(mask_color)
            addstr(entry.nick)
            black()
            addstr('!')
            attron(mask_color)
            addstr(entry.user)
            black()
            addstr('@')
            attron(mask_color)
            local maxwidth = 63 - #entry.nick - #entry.user
            if #entry.host <= maxwidth then
                addstr(entry.host)
                normal()
            else
                addstr(string.sub(entry.host, 1, maxwidth-1))
                normal()
                addstr('…')
            end
            
            -- IP or REASON
            if show_reasons and not entry.connected then
                magenta()
                mvaddstr(y, 80, string.sub(entry.reason, 1, 39))
            elseif entry.org then
                yellow()
                mvaddstr(y, 80, string.sub(entry.org, 1, 39))
            else
                yellow()
                mvaddstr(y, 80, entry.ip)
            end

            blue()
            mvaddstr(y, 120, string.sub(entry.server, 1, 3))
            
            -- GECOS
            normal()
            mvaddstr(y, 124, entry.gecos)

            if entry.reason == 'K-Lined' then
                add_click(y, 0, tty_width, function()
                    entry_to_unkline(entry)
                    highlight = entry.mask
                    highlight_plain = true
                end)
            else
                add_click(y, 0, tty_width, function()
                    entry_to_kline(entry)
                    highlight = entry.mask
                    highlight_plain = true
                end)
            end

            n = n + 1

            ::skip::
        end
    end
    
    if rotating_view then
        local y = (clicon_n+1) % rows
        yellow()
        mvaddstr(y, 0, string.rep('·', tty_width))
    end

    draw_buttons()

    draw_global_load()

    if scroll ~= 0 then
        addstr(string.format(' scroll %d', scroll))
    end
    if filter ~= nil then
        yellow()
        addstr(' FILTER ')
        normal()
        addstr(string.format('%q', filter))
    end
    if conn_filter ~= nil then
        if conn_filter then
            green() addstr(' LIVE')
        else
            red() addstr(' DEAD')
        end
        normal()
    end
    if last_key ~= nil then
        addstr(' key ' .. tostring(last_key))
    end
end

function views.klines()
    draw_global_load()

    local rows = {}
    for nick,avg in pairs(kline_tracker.detail) do
        table.insert(rows, {name=nick,load=avg})
    end
    table.sort(rows, function(x,y)
        return x.name < y.name
    end)

    local y = math.max(tty_height - #rows - 3, 0)

    green()
    mvaddstr(y, 0, '         K-Liner  1m    5m    15m   Kline History')
    normal()
    y = y + 1

    if 3 <= tty_height then
        blue()
        mvaddstr(tty_height-2, 0, string.format('%16s  ', 'KLINES'))
        draw_load(kline_tracker.global)
        normal()
    end

    for _, row in ipairs(rows) do
        if y+2 >= tty_height then return end
        local avg = row.load
        local nick = row.name
        mvaddstr(y, 0, string.format('%16s  ', nick))
        draw_load(avg)
        y = y + 1
    end
    
end

local region_color = {
    US = red,
    EU = blue,
    AU = white,
}

local function in_rotation(region, a1, a2)
    local ips = mrs[region] or {}
    return ips[a1] or ips[a2]
end

local function render_mrs(zone, addr, str)
    if not addr then
        addstr ' '
    elseif in_rotation(zone, addr) then
        yellow()
        addstr(str)
        normal()
    else
        addstr(str)
    end
end

function views.servers()
    draw_global_load()

    local rows = {}
    for server,avg in pairs(conn_tracker.detail) do
        table.insert(rows, {name=server,load=avg})
    end
    table.sort(rows, function(x,y)
        return x.name < y.name
    end)

    local pad = math.max(tty_height - #rows - 2, 0)

    local upcolor = {}
    local next_color = 2

    green()
    mvaddstr(pad,0, '          Server  1m    5m    15m   Connection History                                             Mn  Region AF  Conns  Link')
    normal()
    for i,row in ipairs(rows) do
        if i+1 >= tty_height then return end
        local avg = row.load
        local name = row.name
        local short = string.gsub(name, '%..*', '', 1)
        local info = server_classes[short] or {}
        local in_main = in_rotation('', info.ipv4, info.ipv6)
        if in_main then yellow() end
        mvaddstr(pad+i,0, string.format('%16s  ', short))
        -- Main rotation info
        draw_load(avg)
        normal()
        addstr(' ')
        render_mrs('',          info.ipv4, '4')
        render_mrs('',          info.ipv6, '6')

        -- Regional info
        local region = info.region
        if region then
            region_color[region]()
            addstr('  ' .. region .. ' ')
            normal()
        else
            addstr('     ')
        end
        render_mrs(info.region, info.ipv4, '4')
        render_mrs(info.region, info.ipv6, '6')
        
        -- Family-specific info
        addstr('  ')
        render_mrs('IPV4'     , info.ipv4, '4')
        render_mrs('IPV6'     , info.ipv6, '6')

        local pop = population[name]
        if pop then
            addstr(string.format('  %5d', pop))
        else
            addstr('      ?')
        end

        local link = upstream[name]
        if link then
            local color = upcolor[link]
            if not color then
                color = palette[next_color]
                upcolor[link] = color
                next_color = next_color % #palette + 1
            end
            color()
            addstr('  '..string.sub(link, 1, 4))
            normal()
        else
            addstr('      ')
        end
    end
end

function views.filters()
    draw_global_load()

    local rows = {}
    for server,avg in pairs(filter_tracker.detail) do
        table.insert(rows, {name=server,load=avg})
    end
    table.sort(rows, function(x,y)
        return x.name < y.name
    end)

    local pad = math.max(tty_height - #rows - 3, 0)

    green()
    mvaddstr(pad,0, '          Server  1m    5m    15m   Filter History')
    normal()
    for i,row in ipairs(rows) do
        if i+1 >= tty_height then return end
        local avg = row.load
        local name = row.name
        local short = string.gsub(name, '%.freenode%.net$', '', 1)
        mvaddstr(pad+i,0, string.format('%16s  ', short))
        draw_load(avg)
    end

    if 3 <= tty_height then
        blue()
        mvaddstr(tty_height-2, 0, string.format('%16s  ', 'FILTERS'))
        draw_load(filter_tracker.global)
        normal()
    end
end

local function top_keys(tab)
    local result, i = {}, 0
    for k,v in pairs(tab) do
        i = i + 1
        result[i] = {k,v}
    end
    table.sort(result, function(x,y)
        local a, b = x[2], y[2]
        if a == b then return x[1] < y[1] else return a > b end
    end)
    return result
end

function views.repeats()
    draw_global_load()

    local nick_counts, mask_counts = {}, {}
    for mask, user in users:each() do
        local nick, ip, count = user.nick, user.ip, user.count
        nick_counts[nick] = (nick_counts[nick] or 0) + 1
        mask_counts[mask] = count
    end

    local nicks = top_keys(nick_counts)
    local masks = top_keys(mask_counts)

    for i = 1, tty_height - 1 do
        local nick = nicks[i]
        if nick and nick[2] > 1 then
            mvaddstr(i-1, 0,
                string.format('%4d ', nick[2]))
            blue()
            addstr(string.format('%-16s', nick[1]))
            normal()
        end

        local mask = masks[i]
        if mask then
            mvaddstr(i-1, 22, string.format('%4d ', mask[2]))
            yellow()
            addstr(mask[1])
            normal()
        end
    end
end

local function draw()
    clicks = {}
    erase()
    normal()
    views[view]()
    refresh()
end

-- Server Notice handlers =============================================

local handlers = {}

local function syn_connect(ev)
    local oldkey = ev.nick .. '!' .. ev.user .. '@' .. ev.host
    local entry = users:lookup(oldkey)
    if entry then
        local gateway = string.match(ev.host, '^(.*/)session$')
        if gateway then
            users:delete(oldkey)
            entry.ip = ev.ip
            entry.org = ip_org(ev.ip)
            entry.host = gateway .. 'ip.' .. ev.ip
            local key = entry.nick .. '!' .. entry.user .. '@' .. entry.host
            entry.mask = key .. ' ' .. entry.gecos
            users:insert(key, entry)
        end
    end
end

function handlers.connect(ev)
    local key = ev.nick .. '!' .. ev.user .. '@' .. ev.host
    local server = ev.server
    
    if server == 'syn.' then syn_connect(ev) return end

    local entry = users:insert(key, {count = 0})
    entry.server = ev.server
    entry.gecos = ev.gecos
    entry.host = ev.host
    entry.user = ev.user
    entry.nick = ev.nick
    entry.ip = ev.ip
    entry.time = ev.time
    entry.connected = true
    entry.count = entry.count + 1
    entry.mask = entry.nick .. '!' .. entry.user .. '@' .. entry.host .. ' ' .. entry.gecos
    entry.org = ip_org(entry.ip)
    entry.timestamp = uptime

    while users.n > history do
        users:delete(users:last_key())
    end
    conn_tracker:track(server)
    if show_entry(entry) then
        clicon_n = clicon_n + 1
    end

    local pop = population[ev.server]
    if pop then
        population[ev.server] = pop + 1
    end

    draw()
end

function handlers.disconnect(ev)
    local key = ev.nick .. '!' .. ev.user .. '@' .. ev.host
    local entry = users:lookup(key)

    local pop = population[ev.server]
    if pop then
        population[ev.server] = pop - 1
    end

    if entry then
        entry.connected = false
        entry.reason = ev.reason
        draw()
    end
end

function handlers.kline(ev)
    kline_tracker:track(ev.nick)
end

function handlers.filter(ev)
    filter_tracker:track(ev.server)
    local mask = ev.nick .. '!' .. ev.user .. '@' .. ev.ip
    local user = users:lookup(mask)
    if user then
        user.filters = (user.filters or 0) + 1
    end
end

-- Callback Logic =====================================================

local M = {}

function M.on_input(str)
    local chunk, err = load(str, '=(load)', 't')
    if chunk then
        local returns = {chunk()}
        if select('#', returns) > 0 then
            print(table.unpack(returns))
        end
        draw()
    else
        print(err)
    end
end

local irc_handlers = {}

function irc_handlers.PING()
    send_irc('PONG ZNC\r\n')
end

function irc_handlers.NOTICE(irc)
    if string.match(irc.source, '%.') then
        local note = string.match(irc[2], '^%*%*%* Notice %-%- (.*)$')
        if note then
            local time
            if irc.tags.time then
                time = string.match(irc.tags.time, '^%d%d%d%d%-%d%d%-%d%dT(%d%d:%d%d:%d%d)%.%d*Z$')
            else
                time = os.date '%H:%M:%S'
            end

            local event = parse_snote(time, irc.source, note)
            if event then
                local h = handlers[event.name]
                if h then h(event) end
            end
        end
    end
end

-- RPL_STATS_ILINE
irc_handlers['215'] = function(irc)
    if staged_action ~= nil
    and staged_action.action == 'unkline'
    and staged_action.mask == nil
    then
        staged_action = nil
    end
end

-- RPL_TESTLINE
irc_handlers['725'] = function(irc)
    if irc[2] == 'k'
    and staged_action ~= nil
    and staged_action.action == 'unkline'
    and staged_action.mask == nil
    then
        staged_action.mask = irc[4]
    end
end

-- RPL_TESTMASK_GECOS
irc_handlers['727'] = function(irc)
    if staged_action and '*!'..staged_action.mask == irc[4] then        
        staged_action.count = math.tointeger(irc[2]) + math.tointeger(irc[3])
    end
end

-- RPL_MAP
irc_handlers['015'] = function(irc)
    local server, count = string.match(irc[2], '(%g*)%[...%] %-* | Users: +(%d+)')
    if server then
        population[server] = math.tointeger(count)
    end
end

-- RPL_LINKS
irc_handlers['364'] = function(irc)
    local server = irc[2]
    local linked = irc[3]
    if server == linked then
        links = {[server] = Set{}}
    else
        links[server] = Set{linked}
        links[linked][server] = true
    end
end

-- RPL_END_OF_LINKS
irc_handlers['365'] = function(irc)
    upstream = {}
    local function go(here, up)
        if not upstream[here] then
            upstream[here] = up
            for k, _ in pairs(links[here]) do
                go(k, here)
            end
        end
    end
    go(primary_hub, '')
end

function M.on_irc(irc)
    local f = irc_handlers[irc.command]
    if f then
        f(irc)
    end
end

function M.on_timer()
    uptime = uptime + 1
    conn_tracker:tick()
    kline_tracker:tick()
    filter_tracker:tick()
    draw()
end

local keys = {
    [ncurses.KEY_F1] = function() scroll = 0 view = 'connections' draw() end,
    [ncurses.KEY_F2] = function() view = 'servers'     draw() end,
    [ncurses.KEY_F3] = function() view = 'klines'      draw() end,
    [ncurses.KEY_F4] = function() view = 'filters'     draw() end,
    [ncurses.KEY_F5] = function() view = 'repeats'     draw() end,
    [ncurses.KEY_PPAGE] = function()
        scroll = scroll + math.max(1, tty_height - 1)
        scroll = math.min(scroll, users.n - 1)
        scroll = math.max(scroll, 0)
        draw()
    end,
    [ncurses.KEY_NPAGE] = function()
        scroll = scroll - math.max(1, tty_height - 1)
        scroll = math.max(scroll, 0)
        draw()
    end,
    --[[^L]] [ 12] = function() clear() end,
    --[[ESC]][ 27] = function() reset_filter() end,
    --[[Q ]] [113] = function() conn_filter = true  end,
    --[[W ]] [119] = function() conn_filter = false end,
    --[[E ]] [101] = function() conn_filter = nil   end,
}

function M.on_keyboard(key)
    local f = keys[key]
    if f then
        last_key = nil
        f()
        draw()
    else
        last_key = key
    end
end

function M.on_mrs(x)
    mrs[x.name] = Set(x)
end

function M.on_mouse(y, x)
    for _, button in ipairs(clicks[y] or {}) do
        if button.lo <= x and x < button.hi then
            button.action()
            draw()
            return
        end
    end
end

return M
