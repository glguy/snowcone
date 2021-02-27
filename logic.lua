local black   = '\x1b[30m'
local red     = '\x1b[31m'
local green   = '\x1b[32m'
local yellow  = '\x1b[33m'
local blue    = '\x1b[34m'
local magenta = '\x1b[35m'
local cyan    = '\x1b[36m'
local white   = '\x1b[37m'
local reset   = '\x1b[0m'

-- Load Averages ======================================================

local exp_1  = 1 / math.exp(1/ 1/60)
local exp_5  = 1 / math.exp(1/ 5/60)
local exp_15 = 1 / math.exp(1/15/60)

local function new_load_average()
    return {
        [1] = 0, [5] = 0, [15] = 0,
        sample = function(self, x)
            self[ 1] = self[ 1] * exp_1  + x * (1 - exp_1 )
            self[ 5] = self[ 5] * exp_5  + x * (1 - exp_5 )
            self[15] = self[15] * exp_15 + x * (1 - exp_15)
        end
    }
end

-- Ordered Maps =======================================================

local function new_ordered_map()
    local sentinel = {}
    sentinel.next = sentinel
    sentinel.prev = sentinel

    local obj = { sentinel = sentinel, index = {}, n=0 }

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

    function obj:first_key()
        if self.n > 0 then
            return self.sentinel.next.key
        end
    end

    function obj:last_key()
        if self.n > 0 then
            return self.sentinel.prev.key
        end
    end

    function obj:insert(key, val)
        local node = self.index[key]
        if node then
            unlink_node(node)
        else
            node = {key = key, val = val}
            self.n = self.n + 1
            self.index[key] = node
        end
        link_after(self.sentinel, node)
        return node.val
    end

    function obj:delete(key)
        local node = self.index[key]
        if node then
            self.index[key] = nil
            self.n = self.n - 1
            unlink_node(node)
        end
    end

    function obj:lookup(key)
        local node = self.index[key]
        if node then
            return node.val
        end
    end

    local function each_step(obj, prev)
        local node
        if prev then
            node = obj.index[prev].next
        else 
            node = obj.sentinel.next
        end
        return node.key, node.val
    end

    function obj:each()
        return each_step, self
    end

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
    io.write(string.format('Load: \x1b[37m%.2f %.2f %.2f\x1b[0m ',
               global_load[1], global_load[5], global_load[15]))
    io.flush()

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
        io.flush()
    end
end

function views.servers()
    local rows = {}
    for server,avg in pairs(server_loads) do
        local name = string.gsub(server, '%.freenode%.net$', '', 1)
        table.insert(rows, {name=name,load=avg})
    end
    table.sort(rows, function(x,y) return x.load[1] < y.load[1] end)
    
    io.write(green .. '         Server    1m    5m   15m\n' .. reset)
    for _,row in ipairs(rows) do
        local avg = row.load
        io.write(string.format('%15s  \27[1m%.2f  %.2f  %.2f\27[0m\n', row.name, avg[1], avg[5], avg[15]))
    end
    io.write(string.format('\27[34m%15s  %.2f  %.2f  %.2f\27[0m\n', 'GLOBAL', global_load[1], global_load[5], global_load[15]))
end

local function draw()
    io.write('\r\27[2J')
    views[view]()
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
    for server,v in pairs(connect_counter) do
        if not server_loads[server] then
            server_loads[server] = new_load_average()
        end
        total = total + v
    end
    for server,avg in pairs(server_loads) do
        avg:sample(connect_counter[server] or 0)
    end
    global_load:sample(total)
    connect_counter = {}

    draw()
end

return M
