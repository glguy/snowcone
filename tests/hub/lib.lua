-- Test helpers for hub, run by snowcone without a UI.
--
--   local T = dofile(here .. '/lib.lua')
--   T.case('name', function() ... T.sleep(10) ... end)
--   T.run()
--
-- Cases run one at a time in a coroutine, each against a fresh HUB. A
-- failing case is reported and the rest still run; the run fails at the
-- end if any did. A watchdog timer fails the run if a case never
-- finishes, since the script would otherwise just exit once nothing is
-- pending.

-- What tests keep on HUB and HUB.state, beside hub's own fields
---@class hub.Root
---@field test_draws integer

---@class hub.State
---@field test {loads: integer}
---@field test_touched boolean|nil

local T = {}

T.here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
T.root = T.here .. '/../../hub'
T.init = T.root .. '/init.lua'

-- HUB_TEST_HIDE names modules, separated by commas, that fail to load as
-- if they weren't installed, so a test can run without its optional
-- libraries
for name in (os.getenv 'HUB_TEST_HIDE' or ''):gmatch '[^,]+' do
    package.loaded[name] = nil
    package.preload[name] = function() error(name .. ' hidden by HUB_TEST_HIDE') end
end

local cases = {}
local current_co
local cleanups = {}
T.timers = {} -- keeps raw timers reachable until they fire

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

--- A network's configuration for tests: no features unless extra names
--- them, and short reconnect delays.
---@param id string
---@param extra table|nil fields to set or replace
---@return table
function T.network(id, extra)
    local net = {
        id = id,
        server = {host = id .. '.test', port = 6667},
        identity = {nick = 'me'},
        reconnect = {min_delay = 1, max_delay = 8},
        features = {},
    }
    for k, v in pairs(extra or {}) do net[k] = v end
    return net
end

--- Boot hub with these networks on a fake transport (fake_transport.lua).
---@param networks table[]
---@param opts table|nil more boot options
---@return table fake transport; fake.last() is the newest connection
function T.boot_networks(networks, opts)
    local fake = dofile(T.here .. '/fake_transport.lua').new()
    opts = opts or {}
    opts.transport = fake
    opts.config = opts.config or {}
    opts.config.networks = networks
    T.boot(opts)
    return fake
end

--- Register on a fake connection: CAP LS offering caps, an ACK for each
--- CAP REQ the client sends, the welcome, ISUPPORT and the end of MOTD.
---@param c table fake connection
---@param opts {nick: string|nil, caps: string|nil, isupport: string|nil}|nil
---@return string[] # the lines the client sent, taken
function T.register(c, opts)
    opts = opts or {}
    local nick = opts.nick or 'me'
    local sent = {}
    local function take()
        for _, line in ipairs(c:take()) do
            table.insert(sent, line)
            local req = line:match '^CAP REQ :?(.*)$'
            if req then c:recv(':srv CAP ' .. nick .. ' ACK :' .. req) end
        end
    end
    c:con()
    c:recv(':srv CAP * LS :' .. (opts.caps or ''))
    take()
    c:recv(':srv 001 ' .. nick .. ' :Welcome')
    c:recv(':srv 005 ' .. nick .. ' ' .. (opts.isupport or 'CHANTYPES=#') .. ' :are supported')
    c:recv(':srv 376 ' .. nick .. ' :End of MOTD')
    take()
    return sent
end

--- Load a hub module from the current generation.
function T.require(name)
    return HUB.current.gen.require(name)
end

-- Where a test's command line comes from: a network, by default the first
-- configured, and the buffer it shows there
local function origin(net, target)
    net = net or T.require 'hub.net.manager'.ids()[1]
    return {net = net, context = function(ctx)
        if ctx.net == net then ctx.target = target end
    end}
end

--- Run a command line without the UI, on a network (default: the first
--- configured) with an optional target, as if its buffer were shown.
---@param text string
---@param net string|nil
---@param target string|nil
function T.command(text, net, target)
    T.require 'hub.commands.run'.execute(text, origin(net, target))
end

--- Tab's candidates for a command's argument, as T.command would run it.
function T.complete_args(prefix, seed, net, target)
    return T.require 'hub.commands.run'.complete_args(prefix, seed, origin(net, target))
end

--- Close everything the previous case left behind and forget HUB: its
--- tasks first, whose lookups and children would otherwise answer into a
--- HUB that is gone.
function T.shutdown()
    if HUB and HUB.current then
        T.require 'hub.runtime.task'.cancel_all()
        T.require 'hub.runtime.resources'.close_all()
    end
    HUB = nil
end

--- Run fn when the current case ends, whether it passed or not; the last
--- registered runs first.
---@param fn fun()
function T.cleanup(fn)
    table.insert(cleanups, fn)
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

--- Tracebacks logged, in the details of error lines, oldest first.
function T.tracebacks()
    local OrderedMap = T.require 'hub.lib.OrderedMap'
    local list = {}
    for entry in OrderedMap.reveach(HUB.state.log) do
        local detail = entry.detail
        if detail and detail.kind == 'error' and detail.data.traceback then
            table.insert(list, detail.data.traceback)
        end
    end
    return list
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
    T.timers[t] = true
    t:start(ms, function()
        T.timers[t] = nil
        resume(co)
    end)
    coroutine.yield()
end

--- Wait until pred() is true, for something outside the test's control
--- (a child process, a DNS lookup). Fails after timeout_ms, which may be
--- generous: the wait ends as soon as pred holds.
---@param pred fun(): any
---@param what string
---@param timeout_ms integer|nil default 5000
---@return any # pred's value
function T.wait_until(pred, what, timeout_ms)
    local deadline = snowcone.monotime() + (timeout_ms or 5000) / 1000
    while true do
        local v = pred()
        if v then return v end
        if snowcone.monotime() >= deadline then
            error(string.format('%s: not within %d ms', what, timeout_ms or 5000), 2)
        end
        T.sleep(5)
    end
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
        local failed = {}
        for _, c in ipairs(cases) do
            running = c.name
            local ok, err = xpcall(c.fn, debug.traceback)
            for i = #cleanups, 1, -1 do
                local cleaned, cerr = xpcall(cleanups[i], debug.traceback)
                if ok and not cleaned then ok, err = false, 'cleanup: ' .. cerr end
            end
            cleanups = {}
            T.shutdown()
            if ok then
                print('ok - ' .. c.name)
            else
                table.insert(failed, c.name)
                print('not ok - ' .. c.name .. ': ' .. err)
            end
        end
        finished = true
        watchdog:cancel()
        print(string.format('1..%d', #cases))
        if #failed > 0 then
            error(string.format('%d of %d cases failed: %s', #failed, #cases, table.concat(failed, '; ')), 0)
        end
    end)
    resume(current_co)
end

return T
