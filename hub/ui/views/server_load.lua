-- Connections (connload) and exits (exitload) per server, with the
-- network's topology.
--
-- Click a column title to sort by it, again to reverse. A yellow 4 or 6
-- marks an address in a DNS rotation; S user shedding.
-- View state: ordering, descending.

local common    <const> = require 'hub.features.common'
local dashboard <const> = require 'hub.ui.dashboard'
local draw      <const> = require 'hub.ui.draw'
local scrub     <const> = require 'hub.lib.scrub'

local palette <const> = {draw.red, draw.green, draw.yellow, draw.blue, draw.magenta, draw.cyan, draw.white}

-- A colour for each distinct value, the empty value black
local function make_colours(values)
    local list = {}
    for _, v in pairs(values) do table.insert(list, v) end
    table.sort(list)
    local assignment = {[''] = draw.black}
    local i = 2
    for _, v in ipairs(list) do
        if not assignment[v] then
            assignment[v] = palette[i]
            i = i % #palette + 1
        end
    end
    return assignment
end

local function in_rotation(topo, region, a1, a2)
    local ips = topo.rotations[region] or {}
    return (a1 and ips[a1]) or (a2 and ips[a2])
end

local function render_rotation(win, topo, region, addr, str)
    if not addr then
        win:waddstr ' '
    elseif in_rotation(topo, region, addr) then
        draw.yellow(win)
        win:waddstr(str)
        draw.normal(win)
    else
        win:waddstr(str)
    end
end

local function orderings(topo, info)
    local function by(key)
        return function(x, y)
            local a, b = key(x), key(y)
            return a < b or a == b and x.name < y.name
        end
    end
    return {
        name = function(x, y) return x.name < y.name end,
        load1 = by(function(r) return r.load[1] end),
        load5 = by(function(r) return r.load[5] end),
        load15 = by(function(r) return r.load[15] end),
        region = by(function(r) return (info[r.name] or {}).region or '' end),
        conns = by(function(r) return topo.population[r.name] or -1 end),
        version = by(function(r) return topo.versions[r.name] or '' end),
        uptime = by(function(r) return topo.uptimes[r.name] or '' end),
        uplink = by(function(r) return topo.upstream[r.name] or '' end),
    }
end

local function make_view(id, title, tracker_name, header_colour)
    local function add_column(ctx, win, text, name)
        local vs = ctx.vs
        local active = name == (vs.ordering or 'name')
        if active then draw.bold(win) end
        ctx.add_button(win, text, function()
            if (vs.ordering or 'name') == name then
                vs.descending = not vs.descending
            else
                vs.ordering = name
                vs.descending = false
            end
        end, true)
        if active then draw.bold_(win) end
    end

    return {
        id = id,
        title = id,
        scope = 'net',
        feature = 'snotice',

        render = function(ctx, win)
            local S = dashboard.stores(ctx, win)
            if not S then return end
            local topo = dashboard.topology(ctx)
            local servers = common.servers(ctx.net)
            local tracker = S.trackers[tracker_name]
            local vs = ctx.vs

            local has_versions = next(topo.versions) ~= nil
            local has_uptimes = next(topo.uptimes) ~= nil
            local version_colour = make_colours(topo.versions)
            local uplink_colour = make_colours(topo.upstream)

            local rows = {}
            for server, avg in pairs(tracker.detail) do
                table.insert(rows, {name = server, load = avg})
            end
            local by = orderings(topo, servers.servers)
            local order = by[vs.ordering or 'name'] or by.name
            if vs.descending then
                local forward = order
                order = function(x, y) return forward(y, x) end
            end
            table.sort(rows, order)

            local pad = math.max(ctx.rows - #rows - 1, 0)

            header_colour(win)
            win:wmove(pad, 0)
            add_column(ctx, win, '          Server', 'name')
            add_column(ctx, win, '    1m', 'load1')
            add_column(ctx, win, '    5m', 'load5')
            add_column(ctx, win, '   15m', 'load15')
            win:waddstr(string.format(' %-62s Mn', title))
            add_column(ctx, win, '  Region', 'region')
            win:waddstr ' AF'
            add_column(ctx, win, '  Conns', 'conns')
            add_column(ctx, win, '  Up', 'uplink')
            if has_versions then add_column(ctx, win, '  Version          ', 'version') end
            if has_uptimes then add_column(ctx, win, '  Startup           ', 'uptime') end
            if servers.flags then win:waddstr '  Flags' end
            draw.normal(win)

            for i, row in ipairs(rows) do
                if pad + i >= ctx.rows then break end
                local name = row.name
                local info = servers.servers[name] or {}

                if in_rotation(topo, 'MAIN', info.ipv4, info.ipv6) then draw.yellow(win) end
                win:wmove(pad + i, 0)
                win:waddstr(string.format('%16s ', scrub(name:gsub('%..*', '', 1))))
                dashboard.draw_load(win, row.load)
                draw.normal(win)
                win:waddstr ' '

                render_rotation(win, topo, 'MAIN', info.ipv4, '4')
                render_rotation(win, topo, 'MAIN', info.ipv6, '6')

                local region = info.region
                if region then
                    local colour = dashboard.colour((servers.regions[region] or {}).color)
                    if colour then colour(win) end
                    win:waddstr('  ' .. region .. ' ')
                    draw.normal(win)
                else
                    win:waddstr '     '
                end
                render_rotation(win, topo, region, info.ipv4, '4')
                render_rotation(win, topo, region, info.ipv6, '6')

                win:waddstr '  '
                render_rotation(win, topo, 'IPV4', info.ipv4, '4')
                render_rotation(win, topo, 'IPV6', info.ipv6, '6')

                win:waddstr '  '
                dashboard.add_population(win, topo.population[name])

                local link = topo.upstream[name]
                ;(uplink_colour[link or ''] or draw.normal)(win)
                local linktext = (servers.servers[link] or {}).alias or link or '?'
                win:waddstr(string.format('  %-2.2s', linktext))
                draw.normal(win)

                if has_versions then
                    local version = topo.versions[name]
                    ;(version_colour[version or ''] or draw.normal)(win)
                    win:waddstr(string.format('  %-17.17s', version or '?'))
                    draw.normal(win)
                end

                if has_uptimes then
                    win:waddstr(string.format('  %-19.19s', topo.uptimes[name] or '?'))
                end

                for _, flag in ipairs(servers.flags or {}) do
                    if in_rotation(topo, flag, info.ipv4, info.ipv6) then
                        local colour = dashboard.colour((servers.regions[flag] or {}).color)
                        if colour then colour(win) end
                        win:waddstr(' ' .. flag)
                        draw.normal(win)
                    else
                        for _, expected in ipairs(info.expect or {}) do
                            if expected == flag then
                                draw.red(win)
                                win:waddstr(' ' .. flag)
                                draw.normal(win)
                            end
                        end
                    end
                end

                win:waddstr ' '
                if topo.sheds[name] then
                    draw.red(win)
                    draw.reversevideo(win)
                    win:waddstr 'S'
                    draw.normal(win)
                end
            end
        end,

        status = function(ctx, win)
            -- as render: nothing to show without a network that has snotice
            if not (ctx.net and common.enabled(ctx.net, 'snotice')) then return end
            dashboard.load_status(ctx, win, id == 'connload' and 'cliconn' or 'cliexit', tracker_name)
            local n = 0
            for _, v in pairs(dashboard.topology(ctx).population) do n = n + v end
            ctx.fragment(win)
            draw.magenta(win)
            dashboard.add_population(win, n)
            draw.normal(win)
        end,
    }
end

return {
    make_view('connload', 'Connection History', 'conn', draw.green),
    make_view('exitload', 'Disconnection History', 'exit', draw.red),
}
