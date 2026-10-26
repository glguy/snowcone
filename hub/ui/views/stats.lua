-- What the client is doing and holding, for a developer who wants to know
-- where the memory is going: the process, tasks, native resources, errors,
-- and how full every store is. Counts only; Lua can't size a value, and
-- shared messages would be counted twice anyway. A ring that is full is
-- normal; a count that keeps growing is the thing to investigate.

local clock      <const> = require 'hub.runtime.clock'
local common     <const> = require 'hub.features.common'
local control    <const> = require 'hub.ui.control'
local draw       <const> = require 'hub.ui.draw'
local matching   <const> = require 'hub.lib.matching'
local numerics   <const> = require 'hub.lib.numerics'
local OrderedMap <const> = require 'hub.lib.OrderedMap'
local pretty     <const> = require 'pl.pretty'
local scrub      <const> = require 'hub.lib.scrub'

local numeric_names = {}
for name, n in pairs(numerics) do numeric_names[n] = name end

local function count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

local function ring(om)
    return string.format('%d/%d', OrderedMap.size(om), om.max)
end

-- What a task is waiting for, in a few words
local function waiting_on(t)
    if t.wait == 'irc' then
        local names = {}
        for command in pairs(t.commands or {}) do
            table.insert(names, numeric_names[command] or tostring(command))
        end
        table.sort(names)
        local text = table.concat(names, ' ')
        if #text > 40 then text = text:sub(1, 39) .. '…' end
        return 'irc ' .. text
    elseif t.wait == 'event' then
        return 'event ' .. tostring(t.topic)
    end
    return t.wait or 'running'
end

local function label(win, text)
    draw.blue(win)
    win:waddstr(string.format('%10s: ', text))
    draw.normal(win)
end

local function heading(win, text)
    win:waddstr '\n'
    draw.green(win)
    draw.bold(win)
    win:waddstr(text, '\n')
    draw.normal(win)
end

-- Sorted "name count" pairs, largest first, at most `limit`
local function top(counts, limit)
    local list = {}
    for k, v in pairs(counts) do table.insert(list, {k, v}) end
    table.sort(list, function(a, b)
        if a[2] ~= b[2] then return a[2] > b[2] end
        return a[1] < b[1]
    end)
    local parts = {}
    for i = 1, math.min(limit, #list) do
        table.insert(parts, scrub(tostring(list[i][1])) .. ' ' .. list[i][2])
    end
    if #list > limit then table.insert(parts, '…') end
    return table.concat(parts, ', ')
end

-- One row per network and store family: {net, store, text}
local function store_rows()
    local rows = {}
    local function row(net, store, text) table.insert(rows, {net, store, text}) end

    local S = HUB.state
    row('-', 'client', string.format('status log %s  all consoles %s  plugins %d',
        ring(S.log), ring(S.console_all), count(S.features.plugins)))

    for _, id in ipairs(control.net_ids()) do
        local rec = S.nets[id]
        row(id, 'console', ring(rec.console))

        if rec.irc then
            row(id, 'irc', string.format('users %d  channels %d  batches %d',
                count(rec.irc.users), count(rec.irc.channels), count(rec.irc.batches)))
        end

        local sn = common.get_state('snotice', id)
        if sn then
            local ranges = 0
            for _, tracker in pairs(sn.net_trackers) do ranges = ranges + count(tracker) end
            row(id, 'snotice', string.format('users %s  exits %s  bans %s  channels %s  watches %d  ranges %d',
                ring(sn.users), ring(sn.exits), ring(sn.klines), ring(sn.new_channels), #sn.watches, ranges))
        end

        local topo = common.get_state('topology', id)
        if topo then
            row(id, 'topology', string.format('servers %d  mapped %d  links %d  versions %d',
                count(topo.servers.servers), count(topo.population), count(topo.links), count(topo.versions)))
        end

        local chat = common.get_state('chat', id)
        if chat then
            local messages = 0
            for _, buffer in pairs(chat.buffers) do messages = messages + OrderedMap.size(buffer.messages) end
            row(id, 'chat', string.format('buffers %d  messages %d  list %d',
                count(chat.buffers), messages, OrderedMap.size(chat.list)))
        end
    end
    return rows
end

return {
    id = 'stats',
    title = 'stats',
    scope = 'global',

    render = function(ctx, win)
        draw.green(win)
        win:waddstr '          -= stats =-\n\n'
        draw.normal(win)

        label(win, 'client')
        win:waddstr(_VERSION, '  memory ')
        draw.bold(win)
        win:waddstr(pretty.number(collectgarbage 'count' * 1024, 'M'))
        draw.bold_(win)
        win:waddstr ' '
        ctx.add_button(win, '[GC]', function() collectgarbage() end)
        win:waddstr('  up ', draw.duration(clock.uptime()), '  filters ', matching.kind, '\n')

        label(win, 'code')
        win:waddstr(string.format('generation %d', HUB.current.id))
        local last = HUB.last_reload
        if last then
            win:waddstr('  last load ', os.date('%H:%M:%S', last.at), ' ')
            if last.ok then
                draw.green(win)
                win:waddstr 'ok'
            else
                draw.red(win)
                win:waddstr('failed: ', scrub(last.error or '?'))
            end
            draw.normal(win)
        end
        win:waddstr '\n'

        -- resources by kind, and by owner
        local kinds, owners = {}, {}
        for _, entry in pairs(HUB.resources.items or {}) do
            kinds[entry.kind] = (kinds[entry.kind] or 0) + 1
            owners[entry.owner] = (owners[entry.owner] or 0) + 1
        end
        label(win, 'resources')
        win:waddstr(next(kinds) and top(kinds, 8) or 'none', '\n')
        if next(owners) then
            label(win, 'owners')
            win:waddstr(top(owners, 6), '\n')
        end

        local errors = HUB.errors
        label(win, 'errors')
        if errors and errors.total > 0 then
            draw.red(win)
            win:waddstr(tostring(errors.total))
            draw.normal(win)
            win:waddstr('  ', top(errors.by_origin, 5))
        else
            win:waddstr '0'
        end
        win:waddstr '\n'

        -- tasks, longest waiting first
        local tasks = {}
        local now = clock.now()
        for _, t in pairs(HUB.tasks) do table.insert(tasks, t) end
        table.sort(tasks, function(a, b) return (a.wait_since or now) < (b.wait_since or now) end)
        heading(win, string.format('tasks (%d)', #tasks))
        for _, t in ipairs(tasks) do
            if ncurses.getyx(win) >= ctx.rows - 8 then
                win:waddstr '  …\n'
                break
            end
            win:waddstr(string.format('  %-10.10s %-20.20s ', t.net or '-', scrub(t.name)))
            draw.cyan(win)
            win:waddstr(string.format('%-46.46s', scrub(waiting_on(t))))
            draw.normal(win)
            if t.wait_since then
                win:waddstr(' ', draw.duration(now - t.wait_since))
            end
            win:waddstr '\n'
        end

        heading(win, 'stores (entries, or used/capacity)')
        for _, r in ipairs(store_rows()) do
            if ncurses.getyx(win) >= ctx.rows - 1 then break end
            draw.bold(win)
            win:waddstr(string.format('  %-10.10s ', scrub(r[1])))
            draw.bold_(win)
            draw.blue(win)
            win:waddstr(string.format('%-9s ', r[2]))
            draw.normal(win)
            win:waddstr(r[3], '\n')
        end
    end,
}
