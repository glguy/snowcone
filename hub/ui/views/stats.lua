-- Client statistics (from ircc/view/stats.lua).

local clock      <const> = require 'hub.runtime.clock'
local draw       <const> = require 'hub.ui.draw'
local OrderedMap <const> = require 'hub.lib.OrderedMap'
local matching   <const> = require 'hub.lib.matching'
local pretty     <const> = require 'pl.pretty'
local tablex     <const> = require 'pl.tablex'

local function label(win, txt)
    win:waddstr(string.format('%14s: ', txt))
end

local function value(win, txt)
    draw.bold(win)
    win:waddstr(tostring(txt))
    draw.bold_(win)
    win:waddstr '\n'
end

local function list_stats(ctx, win, name, data)
    win:waddstr(string.format('%-24s %10d %10d ', name, data.n, data.max))
    ctx.add_button(win, '[CLEAR]', function() OrderedMap.reset(data) end)
    win:waddstr '\n'
end

return {
    id = 'stats',
    title = 'stats',
    scope = 'global',

    render = function(ctx, win)
        draw.green(win)
        win:waddstr '          -= stats =-\n\n'
        draw.normal(win)

        label(win, 'Lua version')
        value(win, _VERSION)

        label(win, 'Lua memory')
        draw.bold(win)
        win:waddstr(string.format('%-10s ', pretty.number(collectgarbage 'count' * 1024, 'M')))
        draw.bold_(win)
        ctx.add_button(win, '[GC]', function() collectgarbage() end)
        win:waddstr '\n'

        label(win, 'Uptime')
        value(win, string.format('%d s', math.floor(clock.uptime())))

        label(win, 'Generation')
        value(win, string.format('%d (%s)', HUB.current.id, HUB.current.version))

        label(win, 'Filters')
        value(win, matching.kind)

        label(win, 'Tasks')
        local names = {}
        for _, t in tablex.sort(HUB.tasks) do
            table.insert(names, (t.net and t.net .. ':' or '') .. t.name)
        end
        value(win, #names > 0 and table.concat(names, ' ') or '-')

        label(win, 'Resources')
        local kinds = {}
        for _, entry in pairs(HUB.resources.items or {}) do
            kinds[entry.kind] = (kinds[entry.kind] or 0) + 1
        end
        local parts = {}
        for kind, n in tablex.sort(kinds) do
            table.insert(parts, kind .. '=' .. n)
        end
        value(win, #parts > 0 and table.concat(parts, ' ') or '-')

        win:waddstr '\n'
        draw.green(win)
        win:waddstr 'dataset                          .n       .max\n'
        draw.normal(win)
        list_stats(ctx, win, '/status', HUB.state.log)
        for id, rec in tablex.sort(HUB.state.nets) do
            list_stats(ctx, win, id .. ' console', rec.console)
        end
    end,
}
