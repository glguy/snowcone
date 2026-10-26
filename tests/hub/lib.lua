-- Test helpers for hub, run under `snowcone script`.
--
--   local T = dofile(here .. '/lib.lua')
--   T.case('name', function() ... T.sleep(10) ... end)
--   T.run()
--
-- Cases run one at a time in a coroutine, each against a fresh HUB.
-- A watchdog timer fails the run if a case never finishes, since the
-- script would otherwise just exit once nothing is pending.

local T = {}

T.here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
T.root = T.here .. '/../../hub'
T.init = T.root .. '/init.lua'

local cases = {}
local current_co
local timers = {} -- keeps raw timers reachable until they fire

------------------------------------------------------------------------
-- assertions

local function show(v)
    if type(v) == 'string' then return string.format('%q', v) end
    if type(v) == 'table' then return require 'pl.pretty'.write(v, '') end
    return tostring(v)
end

local function deep_eq(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for k, v in pairs(a) do
        if not deep_eq(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

function T.eq(actual, expected, what)
    if not deep_eq(actual, expected) then
        error(string.format('%s: expected %s, got %s',
            what or 'value', show(expected), show(actual)), 2)
    end
end

function T.ok(v, what)
    if not v then
        error((what or 'assertion') .. ' failed', 2)
    end
    return v
end

--- Expect f to raise an error whose message contains needle.
function T.raises(needle, f, ...)
    local ok, err = pcall(f, ...)
    if ok then
        error('expected an error containing ' .. show(needle), 2)
    end
    if not tostring(err):find(needle, 1, true) then
        error(string.format('expected an error containing %s, got %s', show(needle), show(err)), 2)
    end
end

------------------------------------------------------------------------
-- running hub

--- Boot a fresh hub without a terminal.
---@param opts table|nil extra reload options
function T.boot(opts)
    T.shutdown()
    opts = opts or {}
    opts.init = T.init
    if opts.ui == nil then opts.ui = false end
    if opts.strict == nil then opts.strict = true end
    -- never the user's own configuration files
    if opts.config == nil then opts.config = {} end
    return assert(loadfile(T.init))(opts)
end

--- Reload like /reload does, with optional per-generation options.
---@return boolean ok, string|nil err
function T.reload(opts)
    opts = opts or {}
    opts.init = T.init
    return assert(loadfile(T.init))(opts)
end

--- Load a hub module from the current generation.
function T.require(name)
    return HUB.current.gen.require(name)
end

--- Close everything the previous case left behind and forget HUB.
function T.shutdown()
    if HUB and HUB.current then
        T.require 'hub.runtime.resources'.close_all()
    end
    HUB = nil
end

--- Log lines with a given category, oldest first.
function T.log_lines(category)
    local OrderedMap = T.require 'hub.lib.OrderedMap'
    local lines = {}
    for entry in OrderedMap.reveach(HUB.state.log) do
        if category == nil or entry.category == category then
            table.insert(lines, entry.text)
        end
    end
    return lines
end

------------------------------------------------------------------------
-- async

local function resume(co, ...)
    local ok, err = coroutine.resume(co, ...)
    if not ok then
        error(debug.traceback(co, err), 0)
    end
end

--- Suspend the current case for ms milliseconds.
function T.sleep(ms)
    local co = assert(current_co, 'T.sleep outside a case')
    local t = snowcone.newtimer()
    timers[t] = true
    t:start(ms, function()
        timers[t] = nil
        resume(co)
    end)
    coroutine.yield()
end

function T.case(name, fn)
    table.insert(cases, {name = name, fn = fn})
end

function T.run(timeout_ms)
    local watchdog = snowcone.newtimer()
    local finished = false
    local running = '(none)'
    watchdog:start(timeout_ms or 10000, function()
        if not finished then
            error('timed out in case: ' .. running, 0)
        end
    end)

    current_co = coroutine.create(function()
        for _, c in ipairs(cases) do
            running = c.name
            local ok, err = xpcall(c.fn, debug.traceback)
            if not ok then
                finished = true
                watchdog:cancel()
                T.shutdown()
                error('not ok - ' .. c.name .. ': ' .. err, 0)
            end
            T.shutdown()
            print('ok - ' .. c.name)
        end
        finished = true
        watchdog:cancel()
        print(string.format('1..%d', #cases))
    end)
    resume(current_co)
end

return T
