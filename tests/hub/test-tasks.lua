-- Tasks on a network (runtime/task.lua): waits, timeouts, cancellation,
-- and requests with and without labeled-response.
--
-- Run with:  snowcone tests/hub/test-tasks.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local N = dofile(here .. '/netlib.lua')(T)
local network, boot, rec, record, register, register_labeled = N.network, N.boot, N.rec, N.record, N.register, N.register_labeled
local requester = N.requester

T.case('task timeouts, cancellation and DNS', function()
    local fake = boot {network('test')}
    register(fake.last())
    local task = T.require 'hub.runtime.task'
    local results = {}

    task.spawn('waiter', {net = 'test'}, function(t)
        results.wait = t:wait_irc({'NEVER'}, 20) or 'timed out'
    end)
    local sleeper = task.spawn('sleeper', {}, function(t)
        t:sleep(20)
        results.slept = true
    end)
    task.cancel(sleeper.id)
    -- canceling the task cancels its lookup
    local dns = task.spawn('dns', {}, function(t)
        results.dns = {t:dnslookup 'localhost'}
    end)
    T.eq(type(dns.lookup), 'userdata', 'lookup handle kept')
    task.cancel(dns.id)
    T.eq(dns.lookup, nil, 'lookup canceled')
    task.spawn('dns2', {}, function(t)
        local err, addr = t:dnslookup 'localhost'
        results.dns2 = err == nil and addr ~= nil
    end)

    T.wait_until(function() return results.wait and results.dns2 ~= nil end, 'the timeout and the lookup')
    T.eq(results, {wait = 'timed out', dns2 = true},
        'timeout resumed with nil; canceled tasks never resumed')
    T.eq(next(HUB.tasks), nil, 'no tasks left')
end)

T.case('a labeled request gets its whole reply', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register_labeled(c)
    local sent = record 'irc.sent'

    local result = requester({311, 318}, 1000, 'WHOIS', 'nick', 'nick')
    T.eq(c:take(), {'@label=sc1 WHOIS nick nick'}, 'sent with a label')
    T.eq(sent[1].msg.tags, {label = 'sc1'}, 'label recorded')

    c:recv ':srv 311 me other u h * :someone else' -- not ours
    c:recv '@label=sc1 :srv BATCH +b labeled-response'
    c:recv '@batch=b :remote 311 me nick u h * :Real'
    c:recv '@batch=b :remote 312 me nick remote :info'
    T.eq(result, {}, 'nothing before the batch closes')
    c:recv ':srv BATCH :-b'
    T.eq(result, {'311 nick', done = true}, 'only its reply, filtered by command')

    local acked = requester({311}, 1000, 'WHOIS', 'gone')
    T.eq(c:take(), {'@label=sc2 WHOIS gone'}, 'labels count up')
    c:recv '@label=sc2 :srv ACK'
    T.eq(acked, {done = true}, 'ACK is an empty reply')

    local single = requester({401}, 1000, 'WHOIS', 'x')
    c:recv '@label=sc3 :srv 401 me x :No such nick'
    T.eq(single, {'401 x', done = true}, 'a single labeled message')

    local late = requester({401}, 20, 'WHOIS', 'y')
    T.sleep(100)
    T.eq(late, {done = true}, 'a timeout ends the iteration')
    c:recv '@label=sc4 :srv 401 me y :No such nick' -- late, and harmless
    T.eq(next(HUB.tasks), nil, 'no tasks left')
end)

T.case('a label inside its own batch waits for the batch', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register_labeled(c)
    local result = requester({311, 312}, 1000, 'WHOIS', 'nick')
    c:recv '@label=sc1 :srv BATCH +b labeled-response'
    c:recv '@batch=b;label=sc1 :srv 311 me nick u h * :Real'
    T.eq(result, {}, 'not yet')
    c:recv '@batch=b :srv 312 me nick srv :info'
    c:recv ':srv BATCH -b'
    T.eq(result, {'311 nick', '312 nick', done = true}, 'the whole batch')
end)

T.case('a request from outside its task sends nothing', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register_labeled(c)
    local task = T.require 'hub.runtime.task'
    local t = task.spawn('idle', {net = 'test'}, function(t) t:sleep(1000) end)
    T.raises('own coroutine', t.request, t, {401}, 1000, 'WHOIS', 'x')
    T.eq(c:take(), {}, 'nothing sent')
    T.eq(t.wait, 'sleep', 'its wait untouched')
    task.cancel(t.id)
end)

T.case('without labeled-response a request waits for each reply', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c)
    c:take()

    local result = requester({311, 318}, 1000, 'WHOIS', 'nick')
    T.eq(c:take(), {'WHOIS nick'}, 'sent without a label')
    c:recv ':srv 311 me nick u h * :Real'
    T.eq(result, {'311 nick'}, 'each reply as it arrives')
    c:recv ':srv 318 me nick :End of WHOIS'
    T.eq(result, {'311 nick', '318 nick', done = true}, 'the body ends it')

    local late = requester({311}, 20, 'WHOIS', 'y')
    T.sleep(100)
    T.eq(late, {done = true}, 'a timeout ends the iteration')
end)

T.case('canceling a task kills its child and returns the terminal', function()
    boot {}
    local task = T.require 'hub.runtime.task'
    local tty = T.require 'hub.runtime.tty'
    local piped = task.spawn('piped', {}, function(t)
        t:execute('sleep', {'60'}, '')
        error 'canceled execute resumed'
    end)
    local terminal = task.spawn('terminal', {}, function(t)
        t:execute('sleep', {'60'})
        error 'canceled execute resumed'
    end)
    T.eq(type(piped.process), 'userdata', 'process handle kept')
    T.eq(tty.suspended(), true, 'terminal lent to the child')
    task.cancel(piped.id)
    task.cancel(terminal.id)
    T.eq(piped.process, nil, 'process canceled')
    T.eq(tty.suspended(), false, 'terminal returned')
    -- a child left running would keep the script past ctest's timeout
end)

T.case('a closing network cancels its tasks', function()
    local fake = boot {network('test')}
    local c = fake.last()
    register(c)
    local task = T.require 'hub.runtime.task'
    local t = task.spawn('scoped', {net = 'test'}, function(t) t:wait_irc {'NEVER'} end)
    c:finish 'reset'
    T.eq(HUB.tasks[t.id], nil, 'canceled')
end)

T.case('a task waiting on wait_irc resumes after a reload', function()
    local fake = boot {network('test')}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :'
    c:take()

    T.ok(T.reload {}, 'reload while registration waits for 001')
    local sent = record 'irc.sent'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 376 me :End of MOTD'
    T.eq(rec().phase, 'connected', 'registration finished')
    T.eq(#sent, 1, 'its MODE went through the new generation')
    T.eq(sent[1].msg.command, 'MODE', 'command')
end)

T.run()
