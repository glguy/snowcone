-- Reload behavior of hub's runtime.
--
-- Run with:  snowcone tests/hub/test-reload.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')

-- A module whose route records which version of it handled a call
local function marker(version)
    return string.format([[
local M = {}
M.version = %q
M.routes = {
    ['test.fire'] = function(...)
        table.insert(HUB.test_fired, {M.version, ...})
    end,
}
function M.init_state(S)
    S.test = S.test or {loads = 0}
    S.test.loads = S.test.loads + 1
end
return M
]], version)
end

local function with_marker(version)
    return {
        modules = {'hub.test.marker'},
        overrides = {['hub.test.marker'] = marker(version)},
    }
end

T.case('boot makes generation 1 with state', function()
    T.boot()
    T.eq(HUB.generation, 1, 'generation')
    T.eq(HUB.current.id, 1, 'current id')
    T.ok(HUB.state.log, 'log in state')
    T.eq(T.log_lines 'app', {'started'}, 'app log')
end)

T.case('reload keeps state and swaps code', function()
    T.boot(with_marker 'v1')
    HUB.test_fired = {}
    local state = HUB.state
    T.require 'hub.runtime.log'.add('test', 'before reload')

    T.ok(T.reload(with_marker 'v2'), 'reload succeeded')
    T.eq(HUB.generation, 2, 'generation')
    T.ok(HUB.state == state, 'state table is the same object')
    T.eq(HUB.state.test.loads, 2, 'init_state ran once per load')
    T.eq(T.log_lines 'test', {'before reload'}, 'log survives')

    HUB.current.routes['test.fire']()
    T.eq(HUB.test_fired, {{'v2'}}, 'new route runs')
end)

T.case('a reload that fails to load keeps the old generation', function()
    T.boot(with_marker 'v1')
    HUB.test_fired = {}
    local before = HUB.current

    local ok, err = T.reload {
        modules = {'hub.test.marker'},
        overrides = {['hub.test.marker'] = 'error "boom at load"'},
    }
    T.eq(ok, false, 'reload result')
    T.ok(err:find('boom at load', 1, true), 'error message')
    T.ok(HUB.current == before, 'old generation still current')
    T.eq(HUB.generation, 1, 'generation unchanged')

    local errors = T.log_lines 'error'
    T.ok(errors[#errors]:find('reload: ', 1, true), 'failure logged')

    HUB.current.routes['test.fire']()
    T.eq(HUB.test_fired, {{'v1'}}, 'old code still works')

    -- syntax errors too
    ok = T.reload {
        modules = {'hub.test.marker'},
        overrides = {['hub.test.marker'] = 'return {'},
    }
    T.eq(ok, false, 'syntax error reload result')
    T.ok(HUB.current == before, 'still the old generation')

    -- and the next good reload works
    T.ok(T.reload(with_marker 'v3'), 'good reload after failures')
    HUB.current.routes['test.fire']()
    T.eq(HUB.test_fired, {{'v1'}, {'v3'}}, 'new code after recovery')
end)

T.case('a module may not create globals', function()
    T.boot()
    local ok, err = T.reload {
        modules = {'hub.test.leak'},
        overrides = {['hub.test.leak'] = 'leaked = 1 return {}'},
    }
    T.eq(ok, false, 'reload result')
    T.ok(err:find('undeclared global: leaked', 1, true), 'error names the global')
    T.eq(rawget(_G, 'leaked'), nil, 'no global was made')
end)

T.case('a configuration error fails the reload without a traceback', function()
    T.boot()
    local ok, err = T.reload {config = {networks = {{id = 'x'}}}}
    T.eq(ok, false, 'reload result')
    T.ok(err:find('networks', 1, true), 'error names the setting')
    T.ok(not err:find('traceback', 1, true), 'no traceback in the error')
    T.eq(T.tracebacks(), {}, 'no traceback logged')
end)

T.case('conflicting routes fail the load', function()
    T.boot()
    local ok, err = T.reload {
        modules = {'hub.test.dup'},
        overrides = {['hub.test.dup'] = "return {routes = {['app.tick'] = function() end}}"},
    }
    T.eq(ok, false, 'reload result')
    T.ok(err:find('route app.tick is already defined', 1, true), err)
end)

T.case('a load that fails wiring leaves state alone', function()
    T.boot()
    local ok = T.reload {
        modules = {'hub.test.dup'},
        overrides = {['hub.test.dup'] = [[
return {
    routes = {['app.tick'] = function() end},
    init_state = function(S) S.test_touched = true end,
}
]]},
    }
    T.eq(ok, false, 'reload result')
    T.eq(HUB.state.test_touched, nil, 'its init_state never ran')
end)

T.case('a task canceled by a task it woke ends at its next wait', function()
    T.boot()
    local task = T.require 'hub.runtime.task'
    local bus = T.require 'hub.runtime.bus'
    local a_id
    local reached = {}
    task.spawn('b', {}, function(t)
        t:wait_event 'test.go'
        task.cancel(a_id)
    end)
    local a = task.spawn('a', {}, function(t)
        t:sleep(0)
        bus.emit('test.go', {})      -- wakes b, which cancels a
        table.insert(reached, 'after emit')
        t:execute('true')            -- would stop keyboard input for good
        table.insert(reached, 'after execute')
    end)
    a_id = a.id
    HUB.current.routes['task.wake'](a.id, a.seq)
    T.eq(reached, {'after emit'}, 'its step finished, its next wait ended it')
    T.eq(HUB.tasks[a.id], nil, 'gone')
    T.eq(HUB.tty_suspended or 0, 0, 'the terminal never suspended')
    T.eq(T.tracebacks(), {}, 'quietly')
end)

T.case('a wait_event predicate that raises fails only its task', function()
    T.boot {strict = false}
    local task = T.require 'hub.runtime.task'
    local bus = T.require 'hub.runtime.bus'
    local woken = {}
    local bad = task.spawn('bad', {}, function(t)
        t:wait_event('test.go', function() error 'predicate fails' end)
    end)
    task.spawn('good', {}, function(t)
        t:wait_event 'test.go'
        table.insert(woken, 'good')
    end)
    bus.emit('test.go', {})
    T.eq(woken, {'good'}, 'later waiters woken')
    T.eq(HUB.tasks[bad.id], nil, 'the failing task canceled')
    local errors = T.log_lines 'error'
    T.ok(errors[#errors]:find('task bad: ', 1, true), errors[#errors])
end)

T.case('a timer started before reload fires into new code', function()
    T.boot(with_marker 'v1')
    HUB.test_fired = {}
    local timer = T.require 'hub.runtime.timer'
    timer.start('test', 20, 'test.fire', 'bound', 7)

    T.ok(T.reload(with_marker 'v2'), 'reload')
    T.sleep(50)
    T.eq(HUB.test_fired, {{'v2', 'bound', 7}}, 'fired once into v2 with bound args')

    local resources = T.require 'hub.runtime.resources'
    for _, entry in resources.each() do
        T.ok(entry.kind ~= 'timer', 'fired timer released')
    end
end)

T.case('a canceled timer does not fire', function()
    T.boot(with_marker 'v1')
    HUB.test_fired = {}
    local timer = T.require 'hub.runtime.timer'
    local id = timer.start('test', 10, 'test.fire')
    timer.cancel(id)
    T.sleep(30)
    T.eq(HUB.test_fired, {}, 'nothing fired')
end)

T.case('trampolines pass bound and call arguments to the current route', function()
    T.boot(with_marker 'v1')
    HUB.test_fired = {}
    local dispatch = T.require 'hub.runtime.dispatch'
    local cb = dispatch.trampoline('test.fire', 'a', 'b')

    cb('c')
    T.ok(T.reload(with_marker 'v2'), 'reload')
    cb('d', 'e')
    cb()
    T.eq(HUB.test_fired, {
        {'v1', 'a', 'b', 'c'},
        {'v2', 'a', 'b', 'd', 'e'},
        {'v2', 'a', 'b'},
    }, 'calls')
end)

T.case('route errors are logged, and raised only in strict mode', function()
    T.boot {
        modules = {'hub.test.bad'},
        overrides = {['hub.test.bad'] = "return {routes = {['test.bad'] = function() error 'kaboom' end}}"},
    }
    local dispatch = T.require 'hub.runtime.dispatch'
    local cb = dispatch.trampoline 'test.bad'

    T.raises('kaboom', cb)
    HUB.boot.strict = false
    cb()
    local errors = T.log_lines 'error'
    T.ok(errors[#errors]:find('test.bad: ', 1, true), 'logged with route name')
    T.ok(#T.tracebacks() > 0, 'traceback logged')
end)

T.case('errors raised at level 0 are logged without a traceback', function()
    T.boot()
    HUB.boot.strict = false
    local bus = T.require 'hub.runtime.bus'
    local task = T.require 'hub.runtime.task'

    task.spawn('expected', {}, function() error('bad input', 0) end)
    bus.on(HUB.current.bus, 'test.expected', 'test', function() error('bad event', 0) end)
    bus.emit('test.expected', {})
    local errors = T.log_lines 'error'
    T.eq(errors[#errors - 1], 'task expected: bad input', 'task error logged')
    T.eq(errors[#errors], 'test.expected (test): bad event', 'subscriber error logged')
    T.eq(T.tracebacks(), {}, 'no traceback logged')

    task.spawn('bug', {}, function() error 'kaboom' end)
    T.ok(#T.tracebacks() > 0, 'traceback logged for an error from code')
end)

T.case('messages draw only at the end of a read', function()
    -- A stand-in for the UI and for the connection callback's MSG handling
    T.boot {
        modules = {'hub.test.screen'},
        overrides = {['hub.test.screen'] = [[
local dispatch = require 'hub.runtime.dispatch'
return {routes = {
    ['ui.draw'] = function() HUB.test_draws = HUB.test_draws + 1 end,
    ['test.msg'] = function(flush)
        dispatch.dirty()
        if not flush then dispatch.defer_draw() end
    end,
}}]]},
    }
    HUB.test_draws = 0
    local dispatch = T.require 'hub.runtime.dispatch'
    local cb = dispatch.trampoline 'test.msg'

    for _ = 1, 50 do cb(false) end
    T.eq(HUB.test_draws, 0, 'no draws mid-read')
    cb(true)
    T.eq(HUB.test_draws, 1, 'one draw at the end of the read')
    cb(true)
    T.eq(HUB.test_draws, 2, 'each read draws')

    -- a deferred change is drawn by the next callback that doesn't defer
    cb(false)
    dispatch.trampoline 'log.add' ('test', 'key pressed')
    T.eq(HUB.test_draws, 3, 'later callback draws the deferred change')
end)

T.case('reloads, errors and waits are tracked for /stats', function()
    T.boot {
        modules = {'hub.test.bad'},
        overrides = {['hub.test.bad'] = "return {routes = {['test.bad'] = function() error 'kaboom' end}}"},
    }
    T.eq(HUB.last_reload.ok, true, 'first load ok')

    T.reload {overrides = {['hub.app'] = 'error "broken app"'}}
    T.eq(HUB.last_reload.ok, false, 'failed load recorded')
    T.ok(HUB.last_reload.error:find('broken app', 1, true), HUB.last_reload.error)

    HUB.boot.strict = false
    local cb = T.require 'hub.runtime.dispatch'.trampoline 'test.bad'
    cb()
    cb()
    T.eq(HUB.errors.by_origin['test.bad'], 2, 'errors by origin')
    T.eq(HUB.errors.total >= 3, true, 'the failed reload counts too')

    local task = T.require 'hub.runtime.task'
    local t = task.spawn('waiter', {}, function(t) t:sleep(60000) end)
    T.ok(t.wait_since, 'wait start recorded')
    task.cancel(t.id)
end)

-- Write a configuration file choosing ui.profile
local function write_config(filename, profile)
    local f = assert(io.open(filename, 'w'))
    f:write(string.format("[ui]\nprofile = '%s'\n", profile))
    f:close()
end

T.case('/reload with a file reads that file from then on', function()
    local dir = os.tmpname()
    os.remove(dir)
    assert(require 'pl.path'.mkdir(dir))
    local chosen = dir .. '/chosen.toml'
    write_config(chosen, 'chat')

    T.boot()
    T.eq(HUB.current.config.file, '(provided)', 'the boot configuration')

    T.command('reload ' .. chosen)
    T.sleep(50)
    T.eq({HUB.current.config.file, HUB.current.config.ui.profile}, {chosen, 'chat'}, 'the chosen file')
    T.eq(HUB.config_file, chosen, 'remembered')
    T.eq(T.require 'hub.runtime.config'.resolve_path 'servers.toml', dir .. '/servers.toml',
        'relative paths beside the file')

    write_config(chosen, 'dashboard')
    T.ok(T.reload(), 'a reload without a file')
    T.eq(HUB.current.config.ui.profile, 'dashboard', 'reads the chosen file again')

    T.command('reload ' .. dir .. '/missing.toml')
    T.sleep(50)
    T.eq(HUB.last_reload.ok, false, 'a missing file fails the reload')
    T.eq(HUB.config_file, chosen, 'and is not remembered')
    T.ok(T.reload(), 'a reload without a file')
    T.eq(HUB.current.config.file, chosen, 'still reads the chosen file')

    local lua = dir .. '/hub.lua'
    assert(require 'pl.file'.write(lua, 'return {}'))
    local ok, err = T.reload {config_file = lua}
    T.eq(ok, false, 'a Lua file is refused')
    T.ok(tostring(err):find('TOML', 1, true), err)
    os.remove(lua)

    require 'pl.dir'.rmtree(dir)
end)

T.case('the tick runs only when asked for', function()
    T.boot()
    local resources = T.require 'hub.runtime.resources'
    T.eq(next(HUB.resources.items or {}), nil, 'no timers headless')
    T.boot {tick = true}
    local n = 0
    for _, entry in resources.each() do
        if entry.kind == 'timer' and entry.owner == 'app' then n = n + 1 end
    end
    T.eq(n, 1, 'one tick timer')
end)

T.run()
