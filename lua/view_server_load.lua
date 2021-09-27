local palette = {black, red, green, yellow, blue, magenta, cyan, white}

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

return function(title, label, color, tracker)
return function()
    draw_global_load(label, tracker)

    local rows = {}
    for server,avg in pairs(tracker.detail) do
        table.insert(rows, {name=server,load=avg})
    end
    table.sort(rows, function(x,y)
        return x.name < y.name
    end)

    local pad = math.max(tty_height - #rows - 2, 0)

    local upcolor = {}
    local next_color = 2

    ncurses.attron(color)
    mvaddstr(pad,0, string.format('          Server  1m    5m    15m  %-62s Mn  Region AF  Conns  Link', title))
    normal()
    for i,row in ipairs(rows) do
        if i+1 >= tty_height then return end
        local avg = row.load
        local name = row.name
        local short = string.gsub(name, '%..*', '', 1)
        local info = server_classes[short] or {}
        local in_main = in_rotation('', info.ipv4, info.ipv6)
        if in_main then yellow() end
        mvaddstr(pad+i,0, string.format('%16s ', short))
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

        add_population(population[name])

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
end
