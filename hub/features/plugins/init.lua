-- Plugins.
--
-- `[plugins] modules` names files in `[plugins] directory` (default:
-- plugins/ in the configuration directory). A plugin file returns a
-- function, called with the api below.
--
-- Plugins start once their generation is current, after the previous
-- generation's plugins are stopped, so a plugin never acts while its
-- generation might still fail to load. Subscriptions, commands and views
-- belong to the generation; the resources and tasks a plugin started are
-- closed when the next generation starts its plugins. A plugin error goes
-- to the status view with its name and never breaks the client.
--
-- api:
--   api.name, api.state (persistent: state.features.plugins[name])
--   api.on(topic, fn)                subscribe to an event
--   api.command(name, spec, fn, help, usage, opts)  fn(ctx, ...) as for
--                                    built-in commands; usage such as
--                                    'nick [count]'; opts {net = true} makes
--                                    it act on a network (ctx.net, /x@net)
--   api.view(id, {title, render, keypress, status, modes})
--   api.show_view(id)                show a view, the plugin's or another
--   api.detail(kind, {title, render, keypress, modes, wide})
--   api.open_detail(kind, net, data) show something in the detail pane
--   api.send(net, cmd, ...)  api.log(fmt, ...)
--   api.task(name, fn, ...)          a task, fn(t, ...)
--   api.net_task(net, name, fn, ...) a task on a network: t:send, t:request
--                                    and t:wait_irc use it, and it ends
--                                    with the connection
--   api.timer(ms, fn) -> id, api.cancel_timer(id)
--   api.httpd(host, service, handler) -> resource id; handler(method,
--             target, body, headers) returns status, body, headers (no
--             status is a 500); on a failure it is called (nil, what,
--             message)
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

-- The callback of each timer that hasn't fired, by the timer's id
local timer_callbacks = {}

-- Words for a spec's arguments, for a plugin command that gives no usage
local spec_words <const> = {
    g = 'word', r = 'text', R = '[text]', i = 'number', f = 'number',
    v = 'name', q = "'text'", p = 'path',
}
local function spec_usage(spec)
    if spec == nil or spec == '' then return nil end
    return (spec:gsub('%$(.)', function(c) return spec_words[c] or '...' end))
end

local function owner(name)
    return 'plugin:' .. name
end

local function report(name, what, err)
    log.error('plugin ' .. name .. ' ' .. what, err)
end

local function guard(name, what, f, ...)
    local ok, err = xpcall(f, traceback, ...)
    if not ok then report(name, what, err) end
    return ok, err
end

-- fn, reporting its errors as the plugin's. A canceled task's quiet end
-- passes through.
local function guarded(name, what, fn)
    return function(...)
        local result = table.pack(xpcall(fn, traceback, ...))
        if result[1] then
            return table.unpack(result, 2, result.n)
        end
        local err = result[2]
        if type(err) == 'table' and err.task_canceled then
            error(err, 0)
        end
        report(name, what, err)
    end
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

    function api.command(command, spec, fn, help, usage, opts)
        guard(name, 'command ' .. command, current.add_command, owner(name), {
            name = command, spec = spec, fn = guarded(name, 'command ' .. command, fn),
            help = help or ('from plugin ' .. name),
            usage = usage or spec_usage(spec),
            group = 'plugin ' .. name,
            scope = opts and opts.net and 'net' or nil,
        })
    end

    function api.view(id, view)
        view.id = id
        view.title = view.title or id
        view.scope = view.scope or 'global'
        view.origin = 'plugin ' .. name .. ' view ' .. id
        if guard(name, 'view ' .. id, current.add_view, owner(name), view) then
            table.insert(entry.views, id)
        end
    end
    function api.show_view(id) dispatch.show_view(id) end
    function api.detail(kind, record)
        record.kind = kind
        record.origin = 'plugin ' .. name .. ' detail ' .. kind
        guard(name, 'detail ' .. kind, dispatch.add_detail_kind, record)
    end
    function api.open_detail(kind, net, data) dispatch.open_detail(kind, net, data) end

    function api.send(net, cmd, ...) return send.send(net, cmd, ...) end
    function api.log(fmt, ...) log.add(name, fmt, ...) end
    function api.task(task_name, fn, ...)
        return task.spawn(task_name, {owner = owner(name)}, guarded(name, 'task ' .. task_name, fn), ...)
    end
    function api.net_task(net, task_name, fn, ...)
        return task.spawn(task_name, {owner = owner(name), net = net}, guarded(name, 'task ' .. task_name, fn), ...)
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
    -- a table of strings, booleans, finite numbers and such tables, written
    -- whole: to a new file renamed over the old, so a crash leaves one or
    -- the other
    function api.save(value)
        local function check(v, where)
            local kind = type(v)
            if kind == 'number' and (v ~= v or v == math.huge or v == -math.huge) then
                error('api.save: a number that is not finite at ' .. where, 2)
            elseif kind == 'table' then
                for k, x in pairs(v) do
                    check(k, where .. ' (key)')
                    check(x, where .. '.' .. tostring(k))
                end
            elseif kind ~= 'string' and kind ~= 'boolean' and kind ~= 'number' then
                error('api.save: a ' .. kind .. ' at ' .. where, 2)
            end
        end
        if type(value) ~= 'table' then error('api.save takes a table', 2) end
        check(value, 'value')
        local target = api.path 'dat'
        local temp = target .. '.tmp'
        local ok, err = file.write(temp, pretty.write(value))
        if ok then ok, err = os.rename(temp, target) end
        if not ok then error(target .. ': ' .. tostring(err), 0) end
    end

    -- A timer fires once, so its callback goes when it fires or is canceled
    function api.timer(ms, fn)
        local run = guarded(name, 'timer', fn)
        local id, timer_id
        id = register_callback(function()
            callbacks[id] = nil
            timer_callbacks[timer_id] = nil
            return run()
        end)
        timer_id = timer.start(owner(name), ms, 'plugins.callback', id)
        timer_callbacks[timer_id] = id
        return timer_id
    end
    function api.cancel_timer(timer_id)
        local id = timer_callbacks[timer_id]
        if id then
            callbacks[id] = nil
            timer_callbacks[timer_id] = nil
            timer.cancel(timer_id)
        end
    end

    function api.httpd(host, service, handler)
        local id = register_callback(guarded(name, 'httpd', handler))
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
        report(name, 'start', result)
        return {name = name, error = result}
    end

    if type(result) ~= 'function' then
        local e = 'returned ' .. type(result) .. ', not a function'
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
