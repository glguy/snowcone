local tablex = require 'pl.tablex'

local palette = {black, red, green, yellow, blue, magenta, cyan, white}
local colormap =
  { black = ncurses.black, red = ncurses.red, green = ncurses.green,
    yellow = ncurses.yellow, blue = ncurses.blue, magenta = ncurses.magenta,
    cyan = ncurses.cyan, white = ncurses.white, }

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

return function(title, label, header_color, tracker)

local M = {}

function M:keypress()
end

local orderings = {
    name = function(x,y)
        return x.name < y.name
    end,
    load1 = function(x,y)
        local a = x.load[1]
        local b = y.load[1]
        return a < b or a == b and x.name < y.name
    end,
    load5 = function(x,y)
        local a = x.load[5]
        local b = y.load[5]
        return a < b or a == b and x.name < y.name
    end,
    load15 = function(x,y)
        local a = x.load[15]
        local b = y.load[15]
        return a < b or a == b and x.name < y.name
    end,
    region = function(x,y)
        local a = (servers.servers[x.name] or {}).region or ''
        local b = (servers.servers[y.name] or {}).region or ''
        return a < b or a == b and x.name < y.name
    end,
    conns = function(x,y)
        local a = population[x.name] or -1
        local b = population[y.name] or -1
        return a < b or a == b and x.name < y.name
    end,
    version = function(x,y)
        local a = versions[x.name] or ''
        local b = versions[y.name] or ''
        return a < b or a == b and x.name < y.name
    end,
    uptime = function(x,y)
        local a = uptimes[x.name] or ''
        local b = uptimes[y.name] or ''
        return a < b or a == b and x.name < y.name
    end,
    uplink = function(x,y)
        local a = upstream[x.name] or ''
        local b = upstream[y.name] or ''
        return a < b or a == b and x.name < y.name
    end,
}

local function add_column(text, name)
    local active = name == server_ordering
    if active then bold() end
    add_button(text, function()
        if server_ordering == name then
            server_descending = not server_descending
        else
            server_ordering = name
            server_descending = false
        end
    end, true)
    if active then bold_() end
end

local function make_colors(things)
        table.sort(things)
        local assignment = {[''] = black}
        local i = 2
        for _, v in ipairs(things) do
            if not assignment[v] then
                assignment[v] = palette[i]
                i = i % #palette + 1
            end
        end
        return assignment
end

function M:render()
    local has_versions = next(versions) ~= nil
    local has_uptimes = next(uptimes) ~= nil
    local vercolor = make_colors(tablex.values(versions))
    local upcolor = make_colors(tablex.values(upstream))

    local rows = {}
    for server,avg in pairs(tracker.detail) do
        table.insert(rows, {name=server,load=avg})
    end

    local orderimpl = orderings[server_ordering]
    if server_descending then
        local original = orderimpl
        orderimpl = function(x,y) return original(y,x) end
    end
    table.sort(rows, orderimpl)

    local pad = math.max(tty_height - #rows - 2, 0)

    ncurses.colorset(header_color)
    mvaddstr(pad,0, '')
    add_column('          Server', 'name')
    add_column('    1m', 'load1')
    add_column('    5m', 'load5')
    add_column('   15m', 'load15')
    addstr(string.format(' %-62s Mn', title))
    add_column('  Region', 'region')
    addstr(' AF')
    add_column('  Conns', 'conns')
    add_column('  Up', 'uplink')
    if has_versions then
        add_column('  Version          ', 'version')
    end
    if has_uptimes then
        add_column('  Startup           ', 'uptime')
    end
    if servers.flags then addstr('  Flags') end

    normal()
    for i,row in ipairs(rows) do
        if i+1 >= tty_height then return end
        local avg = row.load
        local name = row.name
        local short = string.gsub(name, '%..*', '', 1)
        local info = servers.servers[name] or {}

        if in_rotation('MAIN', info.ipv4, info.ipv6) then
            yellow()
        end

        -- Name column
        mvaddstr(pad+i,0, string.format('%16s ', short))

        -- Sparkline
        draw_load(avg)
        normal()
        addstr(' ')

        -- Main rotation
        render_mrs('MAIN', info.ipv4, '4')
        render_mrs('MAIN', info.ipv6, '6')

        -- Regional info
        local region = info.region
        if region then
            local color = colormap[servers.regions[region].color]
            if color then ncurses.colorset(color) end
            addstr('  ' .. region .. ' ')
            normal()
        else
            addstr('     ')
        end
        render_mrs(info.region, info.ipv4, '4')
        render_mrs(info.region, info.ipv6, '6')

        -- Family-specific info
        addstr('  ')
        render_mrs('IPV4', info.ipv4, '4')
        render_mrs('IPV6', info.ipv6, '6')

        add_population(population[name])

        local link = upstream[name]
        upcolor[link or '']()
        local linktext = (servers.servers[link] or {}).alias or link or '?'
        addstr(string.format('  %-2.2s', linktext))
        normal()

        if has_versions then
            local version = versions[name]
            vercolor[version or '']()
            addstr(string.format('  %-17.17s', version or '?'))
            normal()
        end

        if has_uptimes then
            addstr(string.format('  %-19.19s', uptimes[name] or '?'))
        end

        for _, flag in ipairs(servers.flags or {}) do
            if in_rotation(flag, info.ipv4) or in_rotation(flag, info.ipv6) then
                local color = colormap[servers.regions[flag].color]
                if color then ncurses.colorset(color) end
                addstr(' '..flag)
                normal()
            elseif tablex.find(info.expect or {}, flag) then
                red()
                addstr(' '..flag)
                normal()
            end
        end
    end
    draw_global_load(label, tracker)
end

return M
end
