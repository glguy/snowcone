-- Plugins.
--
-- `[plugins] modules` names files in `[plugins] directory` (default:
-- plugins/ in the configuration directory). A plugin file returns a
-- function, called with the api below. ircc and dashboard plugins (which
-- return a table) are not supported: port them to this api.
--
-- Plugins start once their generation is current, after the previous
-- generation's plugins are stopped, so a plugin never acts while its
-- generation might still fail to load. Subscriptions, commands and views
-- belong to the generation; the resources and tasks a plugin started are
-- closed when the next generation starts its plugins. A plugin error is
-- logged with its name and never breaks the client.
--
-- api:
--   api.name, api.state (persistent: state.features.plugins[name])
--   api.on(topic, fn)                subscribe to an event
--   api.command(name, spec, fn, help)  fn(ctx, ...) as for built-in commands
--   api.view(id, {title, render, keypress, status})
--   api.send(net, cmd, ...)  api.log(fmt, ...)  api.task(name, fn, ...)
--   api.timer(ms, fn) -> id, api.cancel_timer(id)
--   api.httpd(host, service, handler) -> resource id
--   api.networks() -> ids, api.config (the plugin's [plugins.custom.<name>])
--   api.path(ext) -> <directory>/<name>.<ext>, for the plugin's own files
--   api.load() -> the value last saved, or nil; api.save(value) writes it
--             to <name>.dat (pretty-printed Lua), so it survives restarts

local file      <const> = require 'pl.file'
local path      <const> = require 'pl.path'
local pretty    <const> = require 'pl.pretty'
local config    <const> = require 'hub.runtime.config'
local dispatch  <const> = require 'hub.runtime.dispatch'
local log       <const> = require 'hub.runtime.log'
local manager   <const> = require 'hub.net.manager'
local resources <const> = require 'hub.runtime.resources'
local send      <const> = require 'hub.net.send'
local task      <const> = require 'hub.runtime.task'
local timer     <const> = require 'hub.runtime.timer'
local traceback <const> = require 'hub.lib.traceback'

local M = {}

M.name = 'plugins'

function M.init_state(S)
    S.features.plugins = S.features.plugins or {}
end

-- Loaded plugins of this generation, in load order: {name, error, views}
local loaded = {}
M.loaded = loaded

-- Callbacks of this generation's plugins, by id, for timers and httpd
local callbacks = {}
local next_callback = 0

local function owner(name)
    return 'plugin:' .. name
end

local function report(name, what, err)
    log.count_error('plugin ' .. name)
    log.add_error('plugin', name .. ' ' .. what, err,
        '%s %s: %s', name, what, tostring(err):match '^[^\n]*')
end

local function guard(name, what, f, ...)
    local ok, err = xpcall(f, traceback, ...)
    if not ok then report(name, what, err) end
    return ok, err
end

local function directory()
    local cfg = HUB.state.config.plugins
    local dir = cfg and cfg.directory
    return dir and config.resolve_path(dir) or path.join(config.config_dir(), 'plugins')
end

local function register_callback(f)
    next_callback = next_callback + 1
    callbacks[next_callback] = f
    return next_callback
end

-- api ================================================================

local function make_api(name, entry, current)
    local api = {name = name}
    local S = HUB.state.features.plugins
    S[name] = S[name] or {}
    api.state = S[name]

    local cfg = HUB.state.config.plugins
    api.config = cfg and cfg.custom and cfg.custom[name] or {}

    function api.on(topic, fn)
        current.subscribe(owner(name), topic, function(ev)
            guard(name, topic, fn, ev)
        end)
    end

    function api.command(command, spec, fn, help)
        guard(name, 'command ' .. command, current.add_command, owner(name), {
            name = command, spec = spec, fn = fn,
            help = help or ('from plugin ' .. name),
        })
    end

    function api.view(id, view)
        view.id = id
        view.title = view.title or id
        view.scope = view.scope or 'global'
        if guard(name, 'view ' .. id, current.add_view, owner(name), view) then
            table.insert(entry.views, id)
        end
    end

    function api.send(net, cmd, ...) return send.send(net, cmd, ...) end
    function api.log(fmt, ...) log.add(name, fmt, ...) end
    function api.task(task_name, fn, ...)
        return task.spawn(task_name, {owner = owner(name)}, fn, ...)
    end
    function api.networks() return manager.ids() end

    function api.path(ext) return path.join(directory(), name .. '.' .. ext) end
    function api.load()
        local text = file.read(api.path 'dat')
        if text == nil then return nil end
        local value, err = pretty.read(text)
        if value == nil then error(api.path 'dat' .. ': ' .. tostring(err), 0) end
        return value
    end
    function api.save(value)
        local ok, err = file.write(api.path 'dat', pretty.write(value))
        if not ok then error(api.path 'dat' .. ': ' .. tostring(err), 0) end
    end

    function api.timer(ms, fn)
        local id = register_callback(fn)
        return timer.start(owner(name), ms, 'plugins.callback', id)
    end
    api.cancel_timer = timer.cancel

    function api.httpd(host, service, handler)
        local id = register_callback(handler)
        local listener = snowcone.start_httpd(host, service, dispatch.trampoline('plugins.callback', id))
        return resources.add('httpd', owner(name), listener, 'close')
    end

    return api
end

-- Loading ============================================================

local function load_one(name, current)
    local filename = path.join(directory(), name .. '.lua')
    local chunk, err = loadfile(filename, 't')
    if not chunk then
        report(name, 'load', err)
        return {name = name, error = err}
    end

    local ok, result = xpcall(chunk, traceback)
    if not ok then
        -- old plugins usually fail first on the old clients' modules
        local old_module = tostring(result):match "module '((%a+)%.[%w_.]+)' not found"
        if old_module and (old_module:match '^utils%.' or old_module:match '^components%.') then
            result = 'an ircc or dashboard plugin (it needs ' .. old_module
                .. '); port it to the hub plugin api'
        end
        report(name, 'start', result)
        return {name = name, error = result}
    end

    if type(result) ~= 'function' then
        local e = type(result) == 'table'
            and 'an ircc or dashboard plugin; port it to the hub plugin api'
            or 'returned ' .. type(result) .. ', not a function'
        report(name, 'start', e)
        return {name = name, error = e}
    end

    local entry = {name = name, views = {}}
    local started, serr = guard(name, 'start', result, make_api(name, entry, current))
    if not started then entry.error = serr end
    return entry
end

--- Stop the previous generation's plugins and start the configured ones.
--- `current` gives subscribe(owner, topic, fn), add_command(owner, spec)
--- and add_view(owner, view) for the current generation.
function M.start(current)
    -- in HUB: the previous generation's module is gone
    for _, name in ipairs(HUB.plugins_started or {}) do
        resources.close_owner(owner(name))
        task.cancel_owner(owner(name))
    end
    local cfg = HUB.state.config.plugins
    local names = cfg and cfg.modules or {}
    HUB.plugins_started = names
    for _, name in ipairs(names) do
        table.insert(loaded, load_one(name, current))
    end
end

M.routes = {
    ['plugins.callback'] = function(id, ...)
        local f = callbacks[id]
        if f then return f(...) end
    end,
}

return M
