-- The plugins of this generation, a section each: whether it runs, with
-- the error that stopped it; the errors since it was loaded, and the last
-- of them (a reload starts the count again);
-- the file it loads from and the keys of its [plugins.custom.<name>]
-- (not their values, which may be secret); what it added to the client
-- (views, commands, detail kinds, the events it follows) and what it has
-- running (tasks, timers, HTTP listeners). A plugin whose start failed
-- keeps what it registered first until the next reload, so it shows
-- that too, leaving out what it has none of.
--
-- An error opens in the detail pane, with its traceback, as its line in
-- the status view does. A view is a jump to it, red when it failed to
-- draw; a command, a jump to /help searching for it. Without plugins, it
-- says where they load from and how to list them.

local control  <const> = require 'hub.ui.control'
local draw     <const> = require 'hub.ui.draw'
local fields   <const> = require 'hub.ui.fields'
local matching <const> = require 'hub.lib.matching'
local plugins  <const> = require 'hub.features.plugins'
local scrub    <const> = require 'hub.lib.scrub'

local heading <const> = fields.heading
local label   <const> = fields.label
local key     <const> = fields.key
local words   <const> = fields.words

local indent <const> = string.rep(' ', fields.width + 2)

local function width(text)
    return utf8.len(text) or #text
end

-- Buttons in a row, wrapping under the value column: each {text, action,
-- color}, the color a draw function or nil
local function buttons(ctx, win, list)
    if #list == 0 then
        win:waddstr '-\n'
        return
    end
    for i, b in ipairs(list) do
        local _, x = ncurses.getyx(win)
        if i > 1 and x + width(b[1]) + 1 >= ctx.cols then win:waddstr('\n', indent) end
        if b[3] then b[3](win) end
        ctx.add_button(win, b[1], b[2], true)
        draw.normal(win)
        win:waddstr ' '
    end
    win:waddstr '\n'
end

-- An error's text, opening its detail on a click when its line has one
local function error_text(ctx, win, text, entry)
    draw.red(win)
    local detail = entry and entry.detail
    if detail then
        ctx.add_button(win, scrub(text), function()
            control.open_detail(detail.kind, entry.net, detail.data)
        end, true)
    else
        win:waddstr(scrub(text))
    end
    draw.normal(win)
    win:waddstr '\n'
end

-- What a plugin's owner holds: its tasks by name, and how many timers,
-- and its open HTTP listeners
local function running(entry)
    local own = plugins.owner(entry.name)
    local tasks = {}
    for _, t in pairs(HUB.tasks) do
        if t.owner == own then table.insert(tasks, scrub(t.name)) end
    end
    table.sort(tasks)
    local items = HUB.resources.items or {}
    local timers = 0
    for _, r in pairs(items) do
        if r.owner == own and r.kind == 'timer' then timers = timers + 1 end
    end
    local listeners = {}
    for _, l in ipairs(entry.listeners) do
        if items[l.id] then table.insert(listeners, scrub(l.host .. ':' .. l.service)) end
    end
    return tasks, timers, listeners
end

local function render_plugin(ctx, win, entry)
    local name = entry.name
    heading(win, scrub(name))

    local count, last, first = plugins.errors(entry)
    label(win, 'state')
    if entry.error then
        draw.red(win)
        win:waddstr 'failed  '
        draw.normal(win)
        -- the failure is the first error of this load
        error_text(ctx, win, tostring(entry.error):match '^[^\n]*', first)
    else
        draw.green(win)
        win:waddstr 'running\n'
        draw.normal(win)
    end

    -- since this load; the failure is one of them, and shown already
    if count - (entry.error and 1 or 0) > 0 then
        label(win, 'errors')
        win:waddstr(tostring(count))
        key(win, 'last')
        error_text(ctx, win, last and last.text or '(no longer in the log)', last)
    end

    label(win, 'file')
    win:waddstr(scrub(entry.file), '\n')

    local cfg = HUB.state.config.plugins
    local custom = cfg and cfg.custom and cfg.custom[name]
    if custom then
        local keys = {}
        for k in pairs(custom) do table.insert(keys, scrub(tostring(k))) end
        table.sort(keys)
        label(win, 'config')
        words(ctx, win, name .. ' config', keys)
    end

    -- a failed plugin's rows only for what it has
    local function row(text, n)
        if entry.error and n == 0 then return false end
        label(win, text)
        return true
    end

    local own = plugins.owner(name)
    local views = {}
    for _, id in ipairs(entry.views) do
        local view = HUB.current.views[id]
        -- a stand-in for a view that failed to draw has no owner
        local failed = not (view and view.owner == own)
        table.insert(views, {'→' .. scrub(id), function() control.set_view(id) end, failed and draw.red or nil})
    end
    if row('views', #views) then buttons(ctx, win, views) end

    local names = {}
    for cmd_name, cmd in pairs(HUB.current.commands) do
        if cmd.owner == own then table.insert(names, cmd_name) end
    end
    table.sort(names)
    local commands = {}
    for _, cmd_name in ipairs(names) do
        table.insert(commands, {'/' .. scrub(cmd_name), function()
            control.set_view 'help'
            control.set_filter('help', matching.literal(cmd_name))
        end})
    end
    if row('commands', #commands) then buttons(ctx, win, commands) end

    if entry.details[1] then
        local kinds = {}
        for _, kind in ipairs(entry.details) do table.insert(kinds, scrub(kind)) end
        label(win, 'details')
        words(ctx, win, name .. ' details', kinds)
    end

    local topics = {}
    for topic, subs in pairs(HUB.current.bus.topics) do
        for _, sub in ipairs(subs) do
            if sub.owner == own then
                table.insert(topics, scrub(topic))
                break
            end
        end
    end
    table.sort(topics)
    if row('events', #topics) then words(ctx, win, name .. ' events', topics) end

    local tasks, timers, listeners = running(entry)
    if row('tasks', #tasks) then words(ctx, win, name .. ' tasks', tasks) end
    if row('timers', timers) then win:waddstr(tostring(timers), '\n') end
    if entry.listeners[1] then
        label(win, 'http')
        words(ctx, win, name .. ' http', listeners)
    end
end

return {
    id = 'plugins',
    title = 'plugins',
    scope = 'global',
    document = true,

    -- Esc folds the lists again
    reset = function(vs) vs.expanded = nil end,

    render = function(ctx, win)
        if #plugins.loaded == 0 then
            heading(win, 'Plugins')
            label(win, 'none')
            win:waddstr 'list them in [plugins] modules\n'
            label(win, 'directory')
            win:waddstr(scrub(plugins.directory()), '\n')
            return
        end
        for _, entry in ipairs(plugins.loaded) do
            render_plugin(ctx, win, entry)
        end
    end,
}
