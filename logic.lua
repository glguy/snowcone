local black   = '\x1b[30m'
local red     = '\x1b[31m'
local green   = '\x1b[32m'
local yellow  = '\x1b[33m'
local blue    = '\x1b[34m'
local magenta = '\x1b[35m'
local cyan    = '\x1b[36m'
local white   = '\x1b[37m'
local reset   = '\x1b[0m'

local ticks = {[0]=' ','▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'}

local server_classes = {
    adams = "eu ipv6", barjavel = "eu", ballard = "hubs", bear = "au ipv6",
    beckett = "eu", card = "us", cherryh = "us ipv6", egan = "us ipv6",
    hitchcock = "eu", hobana = "eu ipv6", karatkievich = "us ipv6",
    kornbluth = "eu", leguin = "eu ipv6", miller = "eu ipv6", moon = "us ipv6",
    niven = "eu ipv6", odin = "eu", orwell = "eu", puppettest = "eu ipv6",
    rajaniemi = "eu ipv6", reynolds = "hubs", roddenberry = "us ipv6",
    rothfuss = "us", shelley = "hubs", sinisalo = "eu ipv6",
    stross = "eu webchat", tepper = "us", thor = "eu", tolkien = "us",
    verne = "eu", weber = "us", wilhelm = "eu ipv6", wolfe = "eu ipv6",
    zettel = "tor", traviss = "hubs",
}

-- Load Averages ======================================================

local exp_1  = 1 / math.exp(1/ 1/60)
local exp_5  = 1 / math.exp(1/ 5/60)
local exp_15 = 1 / math.exp(1/15/60)

local load_average_methods = {
    sample = function(self, x)
        self[ 1] = self[ 1] * exp_1  + x * (1 - exp_1 )
        self[ 5] = self[ 5] * exp_5  + x * (1 - exp_5 )
        self[15] = self[15] * exp_15 + x * (1 - exp_15)
        self.recent[self.ix] = x
        self.ix = self.ix % 60 + 1
    end,
    graph = function(self)
        local output = {}
        local j = 1
        for i = self.ix-1, 1, -1 do
            output[j] = ticks[math.min(8, self.recent[i] or 0)]
            j = j + 1
        end
        for i = 60, self.ix, -1 do
            output[j] = ticks[math.min(8, self.recent[i] or 0)]
            j = j + 1
        end
        return table.concat(output)
    end,
}

local load_average_mt = {
    __name = 'load_average',
    __index = load_average_methods,
}

local function new_load_average()
    local o = {[1]=0, [5]=0, [15]=0, recent={}, ix=1}
    setmetatable(o, load_average_mt)
    return o
end

-- Ordered Maps =======================================================

local function unlink_node(node)
    local p = node.prev
    local q = node.next
    p.next = q
    q.prev = p
end

local function link_after(p, node)
    local q = p.next
    p.next = node
    node.next = q
    q.prev = node
    node.prev = p
end 

local ordered_map_methods = {
    first_key = function(self)
        if self.n > 0 then
            return self.next.key
        end
    end,

    last_key = function(self)
        if self.n > 0 then
            return self.prev.key
        end
    end,

    insert = function(self, key, val)
        local node = self.index[key]
        if node then
            unlink_node(node)
        else
            node = {key = key, val = val}
            self.n = self.n + 1
            self.index[key] = node
        end
        link_after(self, node)
        return node.val
    end,

    delete = function(self, key)
        local node = self.index[key]
        if node then
            self.index[key] = nil
            self.n = self.n - 1
            unlink_node(node)
        end
    end,

    lookup = function(self, key)
        local node = self.index[key]
        if node then
            return node.val
        end
    end,

    each = function(self)
        local function each_step(obj, prev)
            local node
            if prev then
                node = obj.index[prev].next
            else 
                node = obj.next
            end
            return node.key, node.val
        end
        
        return each_step, self
    end,
}

local ordered_map_mt = {
    __index = ordered_map_methods,
    __name = "ordered_map",
}

local function new_ordered_map()
    local obj = {index = {}, n = 0}
    obj.next = obj
    obj.prev = obj
    setmetatable(obj, ordered_map_mt)
    return obj
end

-- Global state =======================================================

function reset_filter()
    filter = nil
    highlight = nil
    conn_filter = nil
    count_min = nil
    count_max = nil
end

local defaults = {
    -- state
    users = new_ordered_map(),
    connect_counter = {},
    server_loads = {},
    global_load = new_load_average(),
    view = 'connections',
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

local function draw_global_load()
    io.write(string.format('Load: \x1b[37m%.2f %.2f %.2f\x1b[0m  [%s] ',
    global_load[1], global_load[5], global_load[15], global_load:graph()))
end

local function show_entry(entry)
    return
    (conn_filter == nil or conn_filter == entry.connected) and
    (count_min   == nil or count_min   <= entry.count) and
    (count_max   == nil or count_max   >= entry.count) and
    (filter      == nil or string.match(entry.mask, filter))
end

local views = {}
function conns() view = 'connections' end
function servs() view = 'servers' end
function reps()  view = 'repeats' end

function views.connections()
    local last_time
    local outputs = {}
    local n = 0
    local showtop = (tty_height or 25) - 1
    for _, entry in users:each() do
        if show_entry(entry) then
            local mask_color
            if entry.connected then
                mask_color = green
            else
                mask_color = red
            end

            local make_bold = ''
            if highlight and string.match(entry.mask, highlight) then
                make_bold = '\x1b[1m'
            end

            local col4
            if show_reasons and not entry.connected then
                col4 = magenta .. entry.reason .. reset
            else
                col4 = yellow .. entry.ip .. reset
            end

            local time = entry.time
            local timetxt
            if time == last_time then
                timetxt = '        '
            else
                last_time = time
                timetxt = cyan .. time .. reset
            end

            outputs[showtop-n] = string.format("%s %4d %s%-98s %-48s %s\n",
                timetxt,
                entry.count,
                make_bold,
                mask_color .. entry.nick .. black .. '!' ..
                mask_color .. entry.user .. black .. '@' ..
                mask_color .. entry.host .. reset ,
                col4,
                entry.gecos)

            n = n + 1
            if n >= showtop then break end
        end
    end

    io.write(table.unpack(outputs, showtop-n+1,showtop))
    draw_global_load()

    local filters = {}
    if filter then
        table.insert(filters, string.format('filter=%q', filter))
    end
    if highlight then
        table.insert(filters, string.format('highlight=%q', highlight))
    end
    if conn_filter then
        table.insert(filters, string.format('conn_filter=%s', conn_filter))
    end
    if count_min then
        table.insert(filters, string.format('count_min=%s', count_min))
    end
    if count_max then
        table.insert(filters, string.format('count_max=%s', count_max))
    end
    if filters[1] then
        io.write(table.concat(filters, ' '))
    end
end

function views.servers()
    local rows = {}
    for server,avg in pairs(server_loads) do
        table.insert(rows, {name=server,load=avg})
    end
    table.sort(rows, function(x,y)
        return x.name < y.name
    end)
    
    io.write(green .. '         Server    1m    5m   15m  Class\n' .. reset)
    for _,row in ipairs(rows) do
        local avg = row.load
        local name = row.name
        local short = string.gsub(name, '%.freenode%.net$', '', 1)
        local color = (server_highlights[name] and yellow) or ''
        io.write(string.format('%s%15s\27[0m  \27[1m%.2f  %.2f  %.2f\27[0m  %-10s  [\27[4m%s\27[0m]\n',
            color, short, avg[1], avg[5], avg[15], server_classes[short], avg:graph()))
    end
    io.write(string.format('\27[34m%15s  %.2f  %.2f  %.2f              [%s]',
        'GLOBAL', global_load[1], global_load[5], global_load[15], global_load:graph()))
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
            io.write(string.format('%4d \27[33m%-16s\27[0m   ', nick[2], nick[1]))
        else
            io.write('                        ')
        end

        local mask = masks[i]
        if mask then
            io.write(string.format('%4d \27[34m%-60s\27[0m\n', mask[2], mask[1]))
        else
            io.write('\n')
        end
    end
    draw_global_load()
end

local function draw()
    io.write('\r\27[2J')
    views[view]()
    io.flush()
end

draw()

-- Server Notice parsing ==============================================

local function scrub(str)
    return string.gsub(str, '%c', '~')
end

local function parse_snote(str)
    local time, server, nick, user, host, ip, gecos = string.match(str, '^%[([^][]*)%] %-([^-]*)%- %*%*%* Notice %-%- Client connecting: (%g+) %(([^@]+)@([^)]+)%) %[(.*)%] {%?} %[(.*)%]$')
    if time then
        return {
            name = 'connect',
            server = server,
            nick = nick,
            user = user,
            host = host,
            ip = ip,
            gecos = scrub(gecos),
            time = time
        }
    end

    local time, server, nick, user, host, reason, ip = string.match(str, '^%[([^][]*)%] %-([^-]*)%- %*%*%* Notice %-%- Client exiting: (%g+) %(([^@]+)@([^)]+)%) %[(.*)%] %[([^]]*)%]$')
    if time then
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
    connect_counter[server] = (connect_counter[server] or 0) + 1
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
        h(event)
    end
end

function M.on_timer()

    local total = 0
    server_highlights = {}
    for server,v in pairs(connect_counter) do
        if not server_loads[server] then
            server_loads[server] = new_load_average()
        end
        total = total + v
        server_highlights[server] = true
    end
    for server,avg in pairs(server_loads) do
        avg:sample(connect_counter[server] or 0)
    end
    global_load:sample(total)
    connect_counter = {}

    draw()
end

return M
