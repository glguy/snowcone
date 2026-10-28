-- Tasks: coroutines that wait for IRC messages, events, timers, DNS,
-- child processes and prompts.
--
-- Tasks live in HUB.tasks, outside HUB.state. A task keeps running the code
-- it started with across a reload, but it is woken by the
-- task module of whichever generation is current. The two meet only here:
--
--   record fields  id, name, owner, net, co, seq, wait, commands, timer,
--                  lookup (a dnslookup handle), process (an execute
--                  handle), tty (true while the child has the terminal),
--                  wait_since (optional, for /stats)
--   resume values  wait_irc    the message, or nil on timeout
--                  wait_event  the event, or nil on timeout
--                  sleep       nothing
--                  dnslookup   err_or_nil, addr...
--                  execute     code, stdout, stderr  or  nil, err
--                  prompt      the answer, or nil when aborted
--
-- Keep that list stable. `seq` changes with every wait, so a wakeup meant
-- for an earlier wait (a late timer, say) is ignored.
--
-- A task body gets the task record as its first argument. Methods are
-- found through HUB.current, so a body that calls t:send or t:emit after a
-- reload reaches the new generation's code. Bodies should use those
-- methods rather than module tables held in upvalues.

local bus       <const> = require 'hub.runtime.bus'
local clock     <const> = require 'hub.runtime.clock'
local dispatch  <const> = require 'hub.runtime.dispatch'
local log       <const> = require 'hub.runtime.log'
local timer     <const> = require 'hub.runtime.timer'
local tty       <const> = require 'hub.runtime.tty'

local M = {}

-- Shared by every generation's records. It must not capture this module.
local task_mt <const> = {
    __index = function(_, k)
        return HUB.current.task_methods[k]
    end,
    __tostring = function(t)
        return 'task ' .. t.id .. ' ' .. t.name
    end,
}

local methods = {}
M.methods = methods

--- Live tasks, ordered by id.
local function sorted_tasks()
    local list = {}
    for _, t in pairs(HUB.tasks) do
        table.insert(list, t)
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

-- Clear what the current wait set up. Cancelling a lookup or a child that
-- has finished does nothing; one still running never calls back.
local function end_wait(t)
    if t.timer then
        timer.cancel(t.timer)
        t.timer = nil
    end
    if t.lookup then
        t.lookup:cancel()
        t.lookup = nil
    end
    if t.process then
        t.process:cancel()
        t.process = nil
    end
    if t.tty then
        t.tty = nil
        tty.resume()
    end
    t.wait = nil
    t.commands = nil
    t.topic = nil
    t.predicate = nil
    t.label = nil
end

--- Resume a task if it is still waiting on the wait numbered seq.
function M.resume(id, seq, ...)
    local t = HUB.tasks[id]
    if t == nil or t.seq ~= seq then
        return
    end
    end_wait(t)

    local ok, err = coroutine.resume(t.co, ...)
    if coroutine.status(t.co) == 'dead' then
        HUB.tasks[id] = nil
    end
    if not ok then
        dispatch.report('task ' .. t.name, debug.traceback(t.co, err))
    end
end

--- Start a task. It runs until its first wait before spawn returns.
---@param name string
---@param opts table {net = network id, owner = string}
---@param fn function body, called as fn(t, ...)
---@return table task
function M.spawn(name, opts, fn, ...)
    local id = (HUB.task_next_id or 0) + 1
    HUB.task_next_id = id
    local t = setmetatable({
        id = id,
        name = name,
        owner = opts.owner or name,
        net = opts.net,
        co = coroutine.create(fn),
        seq = 0,
    }, task_mt)
    HUB.tasks[id] = t
    M.resume(id, 0, t, ...)
    return t
end

--- Stop a task wherever it is waiting.
function M.cancel(id)
    local t = HUB.tasks[id]
    if t == nil then return end
    HUB.tasks[id] = nil
    end_wait(t)
    -- a task cancelling itself finishes its current step; nothing resumes it
    if coroutine.running() ~= t.co then
        coroutine.close(t.co)
    end
end

--- Cancel every task, at shutdown.
function M.cancel_all()
    for _, t in ipairs(sorted_tasks()) do
        M.cancel(t.id)
    end
end

--- Cancel every task scoped to a network.
function M.cancel_net(net)
    for _, t in ipairs(sorted_tasks()) do
        if t.net == net then
            M.cancel(t.id)
        end
    end
end

--- Cancel every task an owner started.
function M.cancel_owner(owner)
    for _, t in ipairs(sorted_tasks()) do
        if t.owner == owner then
            M.cancel(t.id)
        end
    end
end

--- Wake tasks of a network waiting for this message's command.
function M.deliver_irc(net, msg)
    for _, t in ipairs(sorted_tasks()) do
        if t.wait == 'irc' and t.net == net and t.commands[msg.command] then
            M.resume(t.id, t.seq, msg)
        end
    end
end

--- Wake tasks waiting for this event. Called by bus.emit.
function M.deliver_event(topic, ev)
    for _, t in ipairs(sorted_tasks()) do
        if t.wait == 'event' and t.topic == topic
        and (t.predicate == nil or t.predicate(ev)) then
            M.resume(t.id, t.seq, ev)
        end
    end
end

--- Answer a task waiting in prompt; nil aborts it.
function M.answer(id, text)
    local t = HUB.tasks[id]
    if t and t.wait == 'prompt' then
        M.resume(id, t.seq, text)
    end
end

-- Methods ============================================================

-- Begin a wait: everything a wakeup needs is recorded before yielding
local function begin_wait(t, kind, timeout_ms)
    if coroutine.running() ~= t.co then
        error('a task can only wait from its own coroutine', 3)
    end
    t.seq = t.seq + 1
    t.wait = kind
    t.wait_since = clock.now()
    if timeout_ms then
        t.timer = timer.start('task', timeout_ms, 'task.wake', t.id, t.seq)
    end
end

local function as_set(commands)
    if commands[1] == nil then return commands end
    local set = {}
    for _, c in ipairs(commands) do set[c] = true end
    return set
end

--- Wait for a message on the task's network whose command is in commands
--- (a list or a set). Returns nil on timeout.
function methods.wait_irc(t, commands, timeout_ms)
    begin_wait(t, 'irc', timeout_ms)
    t.commands = as_set(commands)
    return coroutine.yield()
end

--- Wait for an event on the bus. Returns nil on timeout.
function methods.wait_event(t, topic, predicate, timeout_ms)
    begin_wait(t, 'event', timeout_ms)
    t.topic = topic
    t.predicate = predicate
    return coroutine.yield()
end

function methods.sleep(t, ms)
    begin_wait(t, 'sleep', ms)
    coroutine.yield()
end

---@return string|nil error, string... addresses
function methods.dnslookup(t, name)
    begin_wait(t, 'dns')
    t.lookup = snowcone.dnslookup(name, dispatch.trampoline('task.wake', t.id, t.seq))
    return coroutine.yield()
end

--- Run a program. Without input the child gets the terminal, and the UI
--- is suspended until it exits. Cancelling the task kills the child.
---@param opts table|nil {group = true} kills the child's descendants too
---  on cancel (needs input), {max_output = bytes} limits stdout and stderr
---@return integer|nil exit code, string stdout or error, string stderr
function methods.execute(t, command, args, input, opts)
    begin_wait(t, 'execute')
    if input == nil then
        tty.suspend()
        t.tty = true
    end
    local options = {input = input}
    for k, v in pairs(opts or {}) do options[k] = v end
    local ok, result = pcall(snowcone.execute, command, args or {},
        dispatch.trampoline('task.wake', t.id, t.seq), options)
    if not ok then
        t.seq = t.seq + 1
        end_wait(t)
        error(result, 2)
    end
    t.process = result
    return coroutine.yield()
end

--- Ask the user for a secret. Returns nil when aborted.
function methods.prompt(t, label)
    begin_wait(t, 'prompt')
    t.label = label
    bus.emit('task.prompt', {task = t.id, label = label, net = t.net})
    return coroutine.yield()
end

--- Send an IRC command on the task's network.
function methods.send(t, command, ...)
    return dispatch.route 'net.send' (t.net, command, ...)
end

--- Log a line, tagged with the task's network.
function methods.log(t, category, fmt, ...)
    log.add_net(t.net, category, fmt, ...)
end

function methods.emit(_, topic, ev)
    bus.emit(topic, ev)
end

function methods.cancel(t)
    M.cancel(t.id)
end

--- A module of the current generation, for bodies that need more.
function methods.api(_, name)
    return HUB.current.gen.require(name)
end

M.routes = {
    ['task.wake'] = M.resume,
    -- from an execute started before execute returned a handle
    ['task.executed'] = function(id, seq, use_tty, ...)
        if use_tty then tty.resume() end
        M.resume(id, seq, ...)
    end,
    ['task.event'] = M.deliver_event,
}

return M
