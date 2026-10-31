-- dnslookup returns a handle whose cancel() keeps the callback from ever
-- running; dropping the handle doesn't cancel the lookup.
-- Run with:  snowcone tests/test-dnslookup.lua

local results = {}

-- A lookup whose handle is discarded still completes
snowcone.dnslookup('localhost', function(err, ...)
    results.dropped = {err = err, n = select('#', ...)}
end)
collectgarbage()
collectgarbage()

-- A canceled lookup never calls back
local h = snowcone.dnslookup('localhost', function()
    error 'canceled lookup called back'
end)
assert(type(h) == 'userdata', 'dnslookup returned ' .. type(h))
assert(getmetatable(h) == false, 'metatable reachable')
h:cancel()
h:cancel() -- harmless twice

-- Canceling after completion is harmless
local done
done = snowcone.dnslookup('localhost', function(err, addr)
    results.done = {err = err, addr = addr}
    done:cancel()
end)

-- Failure is reported as a single message
snowcone.dnslookup('nonexistent.invalid', function(err, addr)
    results.failed = {err = err, addr = addr}
end)

-- Checked once everything else has finished; an unfinished lookup would keep
-- the script running, so the timer only needs to outlast them
local check_timer = snowcone.newtimer()
check_timer:start(5000, function()
    assert(results.dropped, 'dropped handle canceled the lookup')
    assert(results.dropped.err == nil and results.dropped.n > 0, tostring(results.dropped.err))
    assert(results.done and results.done.err == nil and results.done.addr, 'lookup failed')
    assert(results.failed and type(results.failed.err) == 'string' and results.failed.addr == nil,
        'failure not reported')
    print 'ok'
end)
