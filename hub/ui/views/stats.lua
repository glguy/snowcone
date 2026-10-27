-- What the client is doing and holding, for a developer who wants to know
-- where the memory is going: the process, tasks, native resources, errors,
-- and how full every store is. Counts only; Lua can't size a value, and
-- shared messages would be counted twice anyway. A ring that is full is
-- normal; a count that keeps growing is the thing to investigate.

local clock      <const> = require 'hub.runtime.clock'
local common     <const> = require 'hub.features.common'
local control    <const> = require 'hub.ui.control'
local draw       <const> = require 'hub.ui.draw'
local fields     <const> = require 'hub.ui.fields'
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

local heading <const> = fields.heading
local label   <const> = fields.label
local key     <const> = fields.key

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

-- One row per network and store family: {net, store, key, value, ...}
local function store_rows()
    local rows = {}
    local function row(...) table.insert(rows, {...}) end

    local S = HUB.state
    row('-', 'client', 'status log', ring(S.log), 'all consoles', ring(S.console_all),
        'plugins', count(S.features.plugins))

    for _, id in ipairs(control.net_ids()) do
        local rec = S.nets[id]
        row(id, 'console', 'ring', ring(rec.console))

        if rec.irc then
            row(id, 'irc', 'users', count(rec.irc.users), 'channels', count(rec.irc.channels),
                'batches', count(rec.irc.batches))
        end

        local sn = common.get_state('snotice', id)
        if sn then
            local ranges = 0
            for _, tracker in pairs(sn.net_trackers) do ranges = ranges + count(tracker) end
            row(id, 'snotice', 'users', ring(sn.users), 'exits', ring(sn.exits), 'bans', ring(sn.klines),
                'channels', ring(sn.new_channels), 'watches', #sn.watches, 'ranges', ranges)
        end

        local topo = common.get_state('topology', id)
        if topo then
            row(id, 'topology', 'servers', count(common.servers(id).servers), 'mapped', count(topo.population),
                'links', count(topo.links), 'versions', count(topo.versions))
        end

        local chat = common.get_state('chat', id)
        if chat then
            local messages = 0
            for _, buffer in pairs(chat.buffers) do messages = messages + OrderedMap.size(buffer.messages) end
            row(id, 'chat', 'buffers', count(chat.buffers), 'messages', messages,
                'list', OrderedMap.size(chat.list))
        end
    end
    return rows
end

return {
    id = 'stats',
    title = 'stats',
    scope = 'global',
    document = true,

    render = function(ctx, win)
        heading(win, 'Client')

        label(win, 'process')
        win:waddstr(_VERSION)
        key(win, 'memory')
        win:waddstr(pretty.number(collectgarbage 'count' * 1024, 'M'), ' ')
        ctx.add_button(win, '[GC]', function() collectgarbage() end)
        key(win, 'up')
        win:waddstr(draw.duration(clock.uptime()))
        key(win, 'filters')
        win:waddstr(matching.kind, '\n')

        label(win, 'code')
        key(win, 'generation')
        win:waddstr(tostring(HUB.current.id))
        local last = HUB.last_reload
        if last then
            key(win, 'last load')
            win:waddstr(os.date('%H:%M:%S', last.at), ' ')
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
        heading(win, string.format('Tasks (%d)', #tasks))
        for _, t in ipairs(tasks) do
            win:waddstr(string.format('  %-10.10s %-20.20s ', t.net or '-', scrub(t.name)))
            draw.cyan(win)
            win:waddstr(string.format('%-46.46s', scrub(waiting_on(t))))
            draw.normal(win)
            if t.wait_since then
                win:waddstr(' ', draw.duration(now - t.wait_since))
            end
            win:waddstr '\n'
        end

        heading(win, 'Stores (entries, or used/capacity)')
        for _, r in ipairs(store_rows()) do
            draw.bold(win)
            win:waddstr(string.format('  %-10.10s ', scrub(r[1])))
            draw.bold_(win)
            draw.blue(win)
            win:waddstr(string.format('%-9s', r[2]))
            draw.normal(win)
            for i = 3, #r, 2 do
                key(win, r[i])
                win:waddstr(tostring(r[i + 1]))
            end
            win:waddstr '\n'
        end
    end,
}
