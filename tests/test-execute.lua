-- execute returns a handle whose cancel() kills the child (its whole group
-- with group = true) and keeps the callback from running; output past
-- max_output kills the child and reports an error.
-- Run with:  snowcone script tests/test-execute.lua

local noop = function() end

local function rejects(what, pattern, ...)
    local ok, err = pcall(snowcone.execute, ...)
    assert(not ok, what .. ' accepted')
    assert(tostring(err):find(pattern, 1, true), what .. ': ' .. tostring(err))
end

rejects('group without input', 'group needs input', 'true', {}, noop, {group = true})
rejects('unknown option', 'unknown option', 'true', {}, noop, {inputs = ''})
rejects('input type', 'input must be a string', 'true', {}, noop, {input = 1})
rejects('group type', 'group must be a boolean', 'true', {}, noop, {input = '', group = 1})
rejects('max_output type', 'max_output must be an integer', 'true', {}, noop, {max_output = 1.5})
rejects('max_output range', 'max_output out of range', 'true', {}, noop, {max_output = -1})

-- Steps run one after another in a coroutine
local co
local function resume(...)
    local ok, err = coroutine.resume(co, ...)
    if not ok then error(debug.traceback(co, err), 0) end
end

local function run(command, args, opts)
    local h = snowcone.execute(command, args, resume, opts)
    return h, coroutine.yield()
end

local function pause(ms)
    local t = snowcone.newtimer()
    t:start(ms, resume)
    coroutine.yield()
end

co = coroutine.create(function()
    -- a handle, with its metatable hidden
    local h, code, out = run('echo', {'hi'})
    assert(type(h) == 'userdata', 'execute returned ' .. type(h))
    assert(getmetatable(h) == false, 'metatable reachable')
    assert(code == 0 and out == 'hi\n', 'echo: ' .. tostring(out))
    h:cancel() -- harmless after completion

    -- a dropped handle doesn't stop the process
    snowcone.execute('echo', {'kept'}, resume)
    collectgarbage()
    collectgarbage()
    code, out = coroutine.yield()
    assert(code == 0 and out == 'kept\n', 'dropped handle stopped the process')

    -- cancel kills the child, and the callback never runs
    h = snowcone.execute('sleep', {'60'}, function() error 'cancelled process called back' end, {input = ''})
    h:cancel()
    h:cancel()

    -- the terminal case: no input, only the child is signalled
    h = snowcone.execute('sleep', {'60'}, function() error 'cancelled process called back' end)
    h:cancel()

    -- group: the shell's background child dies too
    local pidfile = os.tmpname()
    h = snowcone.execute('sh', {'-c', 'sleep 60 & echo $! > "$0"; wait', pidfile},
        function() error 'cancelled process called back' end, {input = '', group = true})
    pause(200)
    local f = assert(io.open(pidfile))
    local pid = f:read 'l'
    f:close()
    assert(pid and pid ~= '', 'no background pid')
    h:cancel()
    pause(200)
    code = select(2, run('kill', {'-0', pid}))
    assert(code ~= 0, 'background child survived its group being killed')
    os.remove(pidfile)

    -- output up to max_output is accepted; one byte more kills the child
    local _, code2, out2 = run('head', {'-c', '1000', '/dev/zero'}, {max_output = 1000})
    assert(code2 == 0 and #out2 == 1000, 'output at the limit: ' .. tostring(out2))
    local _, fail, err = run('yes', {}, {input = '', max_output = 1000})
    assert(fail == nil and err == 'execute: output exceeded 1000 bytes', tostring(err))
    _, fail, err = run('sh', {'-c', 'head -c 2000 /dev/zero >&2'}, {max_output = 1000})
    assert(fail == nil and err == 'execute: output exceeded 1000 bytes', 'stderr: ' .. tostring(err))

    -- A cancelled child left running would keep the script waiting past
    -- ctest's 30 second timeout
    print 'ok'
end)
resume()
