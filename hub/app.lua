-- Application layer: which modules make up a generation, how they are
-- wired together, and what happens when one becomes current.
--
-- A module may export any of:
--   init_state(S)                   see runtime/state.lua
--   routes      [name] = function, targets for trampolines and late calls
--   subscribe(sub)                   sub.on(topic, fn) on the new bus
--   commands    sequence of {name, spec, usage, fn, help, scope, feature, group}
--   views       sequence of view records (ui/init.lua)
--   activate(first)                  runs once the generation is current

local bus        <const> = require 'hub.runtime.bus'
local clock      <const> = require 'hub.runtime.clock'
local config     <const> = require 'hub.runtime.config'
local dispatch   <const> = require 'hub.runtime.dispatch'
local log        <const> = require 'hub.runtime.log'
local resources  <const> = require 'hub.runtime.resources'
local state      <const> = require 'hub.runtime.state'
local timer      <const> = require 'hub.runtime.timer'
local task       <const> = require 'hub.runtime.task'
local mkcommand  <const> = require 'hub.lib.mkcommand'
local manager    <const> = require 'hub.net.manager'
local plugins    <const> = require 'hub.features.plugins'

local M = {}

local function module_names(opts)
    local names = {
        'hub.runtime.dispatch',
        'hub.runtime.clock',
        'hub.runtime.log',
        'hub.runtime.timer',
        'hub.runtime.task',
        'hub.net.send',
        'hub.net.handlers',
        'hub.net.manager',
        'hub.features.common',
        'hub.features.snotice',
        'hub.features.topology',
        'hub.features.oper',
        'hub.features.chat',
        'hub.features.notify',
        'hub.features.plugins',
    }
    if HUB.boot.ui then
        table.insert(names, 'hub.ui')
    end
    table.insert(names, 'hub.commands.core')
    table.insert(names, 'hub.commands.crypto')
    for _, name in ipairs(opts.modules or {}) do
        table.insert(names, name)
    end
    return names
end

local function add_routes(current, name, routes)
    for route, f in pairs(routes) do
        if current.routes[route] then
            error(string.format('%s: route %s is already defined by %s',
                name, route, current.route_owner[route]), 0)
        end
        current.routes[route] = f
        current.route_owner[route] = name
    end
end

local function add_command(current, name, cmd)
    current.command_count = (current.command_count or 0) + 1
    local existing = current.commands[cmd.name]
    if existing then
        error(string.format('%s: command %s is already defined by %s',
            name, cmd.name, existing.owner), 0)
    end
    current.commands[cmd.name] = {
        name = cmd.name,
        spec = cmd.spec,
        -- the arguments as /help shows them, such as 'nick [count]'
        usage = cmd.usage,
        pattern = mkcommand(cmd.spec),
        fn = cmd.fn,
        help = cmd.help,
        scope = cmd.scope or 'global',
        feature = cmd.feature,
        -- where /help lists it: its feature's group unless it names one
        group = cmd.group or cmd.feature,
        -- /help lists a group in the order its commands were added
        order = current.command_count,
        owner = name,
    }
end

--- Load every module and wire up a generation, without making it current.
---@param gen hub.Generation
---@param opts hub.ReloadOptions
---@return hub.Current # ready for HUB.current
function M.build(gen, opts)
    -- read and validate first: a bad file leaves everything as it was
    local cfg = config.load(HUB.boot.args, opts.config or HUB.boot.config)

    local modules = {}
    for _, name in ipairs(module_names(opts)) do
        table.insert(modules, {name = name, module = gen.require(name)})
    end
    table.insert(modules, {name = 'hub.app', module = M})

    state.prepare(modules)

    --- A generation as it runs: its modules and what they registered.
    ---@class hub.Current
    ---@field id integer set when it becomes current
    ---@field modules {name: string, module: any}[] in layer order
    ---@field routes table<string, function>
    ---@field route_owner table<string, string> module that added each route
    ---@field commands table<string, table> by name
    ---@field views table<string, table> by id
    ---@field config table normalized configuration (runtime/config.lua)
    ---@field task_methods hub.Task the methods of every task
    local current = {
        gen = gen,
        modules = modules,
        routes = {},
        route_owner = {},
        bus = bus.new(),
        commands = {},
        views = {},
        config = cfg,
        task_methods = task.methods,
    }

    for _, entry in ipairs(modules) do
        local name, m = entry.name, entry.module
        if type(m) == 'table' then
            if m.routes then
                add_routes(current, name, m.routes)
            end
            if m.subscribe then
                m.subscribe {
                    on = function(topic, fn)
                        bus.on(current.bus, topic, name, fn)
                    end,
                }
            end
            for _, cmd in ipairs(m.commands or {}) do
                add_command(current, name, cmd)
            end
            for _, view in ipairs(m.views or {}) do
                if current.views[view.id] then
                    error(string.format('%s: view %s is already defined', name, view.id), 0)
                end
                current.views[view.id] = view
            end
        end
    end

    return current
end

local function shutdown()
    if HUB.shut_down then return end
    HUB.shut_down = true
    -- networks first, so a closing connection can't schedule a reconnect
    manager.abandon_all()
    -- a task's lookup or child process would keep the event loop running
    task.cancel_all()
    resources.close_all()
    snowcone.shutdown()
end

local function tick()
    timer.start('app', 1000, 'app.tick')
    bus.emit('clock.tick', {now = clock.now()})
    dispatch.dirty()
    collectgarbage 'step'
end

local function activate(first)
    local current = HUB.current
    ---@cast current -nil the loader makes the generation current first
    HUB.last_reload = {at = os.time(), ok = true}
    HUB.state.config = current.config
    for _, warning in ipairs(current.config.warnings) do
        log.add('config', '%s', warning)
    end

    -- networks first, so modules activate with every record in place
    if not HUB.quitting then
        manager.apply_config(HUB.state.config)
    end

    -- plugins before modules activate, so every command and view is in
    -- place; their failures are only logged
    plugins.start {
        subscribe = function(owner, topic, fn)
            bus.on(current.bus, topic, owner, fn)
        end,
        add_command = function(owner, cmd)
            add_command(current, owner, cmd)
        end,
        add_view = function(owner, view)
            if current.views[view.id] then
                error('view ' .. view.id .. ' is already defined', 0)
            end
            view.owner = owner
            current.views[view.id] = view
        end,
    }

    for _, entry in ipairs(current.modules) do
        local m = entry.module
        if type(m) == 'table' and m.activate and m ~= M then
            m.activate(first)
        end
    end

    if HUB.boot.ui then
        dispatch.install_entry()
    end

    if first then
        if HUB.boot.tick then
            timer.start('app', 1000, 'app.tick')
        end
        log.add('app', 'started')
    else
        log.add('app', 'reloaded generation %d', current.id)
    end

    bus.emit('app.reloaded', {generation = current.id, first = first})
    dispatch.dirty()
end

local function reload()
    local init = HUB.boot.init
    local chunk = assert(loadfile(init))
    chunk {init = init}
end

local function reload_failed(err)
    HUB.last_reload = {at = os.time(), ok = false, error = tostring(err):match '^[^\n]*'}
    log.error('reload', err)
    local show = HUB.current.routes['ui.show_view']
    if show then show 'status' end
end

-- Quitting sends QUIT on every network and exits once the servers close
-- the connections, or after a grace period. A second quit exits now.
local function quit()
    if HUB.quitting then
        return shutdown()
    end
    HUB.quitting = true
    bus.emit('app.quit', {})
    manager.quit_all()
    if manager.live_count() == 0 then
        shutdown()
    else
        timer.start('app', manager.quit_grace_ms + 1000, 'app.shutdown')
    end
end

function M.subscribe(sub)
    sub.on('net.closed', function()
        if HUB.quitting and manager.live_count() == 0 then
            shutdown()
        end
    end)
end

M.routes = {
    ['app.activate'] = activate,
    ['app.reload'] = reload,
    ['app.reload_failed'] = reload_failed,
    ['app.tick'] = tick,
    ['app.quit'] = quit,
    ['app.shutdown'] = shutdown,
}

return M
