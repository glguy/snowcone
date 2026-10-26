-- Reload behaviour of hub's runtime (design section 5).
--
-- Run with:  snowcone script tests/hub/test-reload.lua

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
    T.eq(T.log_lines 'app', {'started (phase0)'}, 'app log')
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

-- Design 5.7, reload test 2
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

T.case('conflicting routes fail the load', function()
    T.boot()
    local ok, err = T.reload {
        modules = {'hub.test.dup'},
        overrides = {['hub.test.dup'] = "return {routes = {['app.tick'] = function() end}}"},
    }
    T.eq(ok, false, 'reload result')
    T.ok(err:find('route app.tick is already defined', 1, true), err)
end)

-- Design 5.7, reload test 3
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

T.case('a cancelled timer does not fire', function()
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
    T.ok(#T.log_lines 'trace' > 0, 'traceback logged')
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

T.case('the tick runs only when asked for', function()
    T.boot()
    local resources = T.require 'hub.runtime.resources'
    T.eq(next(HUB.resources.items or {}), nil, 'no timers headless')
    T.boot {tick = true}
    local n = 0
    for _, entry in resources.each() do
        if entry.kind == 'timer' then n = n + 1 end
    end
    T.eq(n, 1, 'one tick timer')
end)

T.run()
