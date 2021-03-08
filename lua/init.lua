local app = require 'pl.app'
local Set = require 'pl.Set'
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

local spinner = {'◴','◷','◶','◵'}

local server_classes = require 'server_classes'
local load_tracker = require 'load_tracker'
local ordered_map = require 'ordered_map'

-- Global state =======================================================

function reset_filter()
    filter = nil
    conn_filter = nil
    count_min = nil
    count_max = nil
end

local defaults = {
    -- state
    users = ordered_map.new(),
    kline_tracker = load_tracker.new(),
    conn_tracker = load_tracker.new(),
    view = 'connections',
    uptime = 0,
    mrs = {},
    scroll = 0,
    -- settings
    history = 1000,
    show_reasons = true,
}

function initialize()
    for k,v in pairs(defaults) do
        _G[k] = v
    end
    reset_filter()
end

for k,v in pairs(defaults) do
    if not _G[k] then
        _G[k] = v
    end
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
    magenta()
    attron(ncurses.A_REVERSE)
    mvaddstr(tty_height-1, 0, 'sn' .. spinner[uptime % #spinner + 1] .. 'wcone')
    attroff(ncurses.A_REVERSE)
    addstr(' CLICON  ')
    draw_load(conn_tracker.global)
    normal()
end

local function show_entry(entry)
    return
    (conn_filter == nil or conn_filter == entry.connected) and
    (count_min   == nil or count_min   <= entry.count) and
    (count_max   == nil or count_max   >= entry.count) and
    (filter      == nil or string.match(entry.mask, filter))
end

local views = {}

function views.connections()
    local skips = scroll or 0
    local last_time
    local n = 0
    for _, entry in users:each() do
        if show_entry(entry) then
            local y = tty_height-n-2
            if y < 0 then break end

            if skips > 0 then skips = skips - 1 goto skip end

            -- TIME
            local time = entry.time
            local timetxt
            if time == last_time then
                mvaddstr(y, 0, '        ')
            else
                last_time = time
                cyan()
                mvaddstr(y, 0, time)
                normal()
            end
            addstr(string.format(" %4d ", entry.count))
            
            -- MASK
            local mask_color = entry.connected and ncurses.green or ncurses.red
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
            else
                yellow()
                mvaddstr(y, 80, entry.ip)
            end
            normal()

            -- GECOS
            mvaddstr(y, 120, entry.gecos)

            n = n + 1

            ::skip::
        end
    end

    draw_global_load()

    if scroll ~= 0 then
        addstr(string.format(' scroll=%d', scroll))
    end
    if filter ~= nil then
        addstr(string.format(' filter=%q', filter))
    end
    if conn_filter ~= nil then
        addstr(string.format(' conn_filter=%s', conn_filter))
    end
    if count_min ~= nil then
        addstr(string.format(' count_min=%s', count_min))
    end
    if count_max ~= nil then
        addstr(string.format(' count_max=%s', count_max))
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
    mvaddstr(y, 0, '         K-Liner  1m    5m    15m   Histogram')
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

    green()
    mvaddstr(pad,0, '          Server  1m    5m    15m   Histogram                                                      Mn  Region AF')
    normal()
    for i,row in ipairs(rows) do
        if i+1 >= tty_height then return end
        local avg = row.load
        local name = row.name
        local short = string.gsub(name, '%.freenode%.net$', '', 1)
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
    erase()
    normal()
    views[view]()
    refresh()
end

-- Server Notice parsing ==============================================

local function scrub(str)
    return string.gsub(str, '%c', '~')
end

local function parse_snote(str)
    local time, server, str = string.match(str, '^%[([^]]*)%] %-([^-]*)%- %*%*%* Notice %-%- (.*)$')
    if time then
        local nick, user, host, ip, class, gecos = string.match(str, '^Client connecting: (%g+) %(([^@]+)@([^)]+)%) %[(.*)%] {([^}]*)} %[([^][]*)%]$')
        if nick then
            return {
                name = 'connect',
                server = server,
                nick = nick,
                user = user,
                host = host,
                ip = ip,
                gecos = scrub(gecos),
                time = time,
                class = class,
            }
        end

        local nick, user, host, reason, ip = string.match(str, '^Client exiting: (%g+) %(([^@]+)@([^)]+)%) %[(.*)%] %[([^][]*)%]$')
        if nick then
            return {
                name = 'disconnect',
                server = server,
                nick = nick,
                user = user,
                host = host,
                reason = scrub(reason),
                ip = ip,
            }
        end

        local nick, user, host, oper, duration, mask, reason = string.match(str, '^([^!]+)!([^@]+)@([^{]+){([^}]*)} added %g+ (%d+) min. K%-Line for %[([^]]*)%] %[(.*)%]$')
        if nick then
            return {
                name = 'kline',
                server = server,
                nick = nick,
                user = user,
                host = host,
                oper = oper,
                mask = mask,
                reason = scrub(reason)
            }
        end
    end
end

-- Server Notice handlers =============================================

local handlers = {}

function handlers.connect(ev)
    local mask = ev.nick .. '!' .. ev.user .. '@' .. ev.ip
    local server = ev.server
    local entry = users:insert(mask, {count = 0})
    entry.gecos = ev.gecos
    entry.host = ev.host
    entry.user = ev.user
    entry.nick = ev.nick
    entry.ip = ev.ip
    entry.time = ev.time
    entry.connected = true
    entry.count = entry.count + 1
    entry.mask = entry.nick .. '!' .. entry.user .. '@' .. entry.host .. ' ' .. entry.gecos

    while users.n > history do
        users:delete(users:last_key())
    end
    conn_tracker:track(server)
    draw()
end

function handlers.disconnect(ev)
    local mask = ev.nick .. '!' .. ev.user .. '@' .. ev.ip
    local entry = users:lookup(mask)
    if entry then
        entry.connected = false
        entry.reason = ev.reason
        draw()
    end
end

function handlers.kline(ev)
    kline_tracker:track(ev.nick)
end

-- Callback Logic =====================================================

local M = {}

function M.on_input(str)
    local chunk, err = load(str, '=(load)', 't')
    if chunk then
        print(chunk())
        draw()
    else
        print(err)
    end
end


function M.on_snote(str)
    local event = parse_snote(str)
    if event then
        local h = handlers[event.name]
        if h then h(event) end
    end
end

function M.on_timer()
    uptime = uptime + 1
    conn_tracker:tick()
    kline_tracker:tick()
    draw()
end

local keys = {
    [ncurses.KEY_F1] = function() scroll = 0 view = 'connections' draw() end,
    [ncurses.KEY_F2] = function() view = 'servers'     draw() end,
    [ncurses.KEY_F3] = function() view = 'klines'      draw() end,
    [ncurses.KEY_F4] = function() view = 'repeats'     draw() end,
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
    --[[^L]] [ 12] = function() clear() draw() end,
    --[[Q ]] [113] = function() conn_filter = true  draw() end,
    --[[W ]] [119] = function() conn_filter = false draw() end,
    --[[E ]] [101] = function() conn_filter = nil   draw() end,
}

function M.on_keyboard(key)
    local f = keys[key]
    if f then
        last_key = nil
        f()
    else
        last_key = key
    end
end

function M.on_mrs(x)
    mrs[x.name] = Set(x)
end

return M
