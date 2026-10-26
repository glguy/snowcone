-- Application layer: which modules make up a generation, how they are
-- wired together, and what happens when one becomes current (design
-- sections 5.5 and 7).
--
-- A module may export any of:
--   init_state(S), migrate(S, from)   see runtime/state.lua
--   routes      [name] = function, targets for trampolines and late calls
--   subscribe(sub)                   sub.on(topic, fn, opts) on the new bus
--   commands    sequence of {name, spec, fn, help, scope}
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

local M = {}

-- Bumped by hand to see at a glance which code is running after a reload
M.version = 'phase2'

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
    }
    if HUB.boot.ui then
        table.insert(names, 'hub.ui')
    end
    table.insert(names, 'hub.commands.core')
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
    local existing = current.commands[cmd.name]
    if existing then
        error(string.format('%s: command %s is already defined by %s',
            name, cmd.name, existing.owner), 0)
    end
    current.commands[cmd.name] = {
        name = cmd.name,
        spec = cmd.spec,
        pattern = mkcommand(cmd.spec),
        fn = cmd.fn,
        help = cmd.help,
        scope = cmd.scope or 'global',
        owner = name,
    }
end

--- Load every module and wire up a generation, without making it current.
---@param gen table loader generation
---@param opts table reload options (runtime/loader.lua)
---@return table the generation, ready for HUB.current
function M.build(gen, opts)
    -- read and validate first: a bad file leaves everything as it was
    local cfg = config.load(HUB.boot.args, opts.config or HUB.boot.config)

    local modules = {}
    for _, name in ipairs(module_names(opts)) do
        table.insert(modules, {name = name, module = gen.require(name)})
    end
    table.insert(modules, {name = 'hub.app', module = M})

    state.prepare(modules)

    local current = {
        gen = gen,
        modules = modules,
        routes = {},
        route_owner = {},
        bus = bus.new(),
        commands = {},
        views = {},
        version = M.version,
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
                    on = function(topic, fn, o)
                        bus.on(current.bus, topic, name, fn, o)
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
    state.commit()
    local current = HUB.current
    HUB.state.config = current.config
    for _, warning in ipairs(current.config.warnings) do
        log.add('config', '%s', warning)
    end

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
        log.add('app', 'started (%s)', current.version)
    else
        log.add('app', 'reloaded generation %d (%s)', current.id, current.version)
    end

    bus.emit('app.reloaded', {generation = current.id, first = first})
    if not HUB.quitting then
        manager.apply_config(HUB.state.config)
    end
    dispatch.dirty()
end

local function reload()
    local init = HUB.boot.init
    local chunk = assert(loadfile(init))
    chunk {init = init}
end

local function reload_failed(err)
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
