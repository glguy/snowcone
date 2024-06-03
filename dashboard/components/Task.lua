local class = require 'pl.class'

local M = class()
M._name = 'Task'

function M:_init(queue, main, ...)
    self.co = coroutine.create(main)
    self.queue = queue
    queue[self] = true
    self:resume(self, ...)
end

function M:wait_irc(command_set)
    self.want_command = command_set
    return coroutine.yield()
end

function M:resume_irc(irc)
    self.want_command = nil
    self:resume(irc)
end

function M:complete()
    return coroutine.status(self.co) == 'dead'
end

function M:resume(...)
    local success, result = coroutine.resume(self.co, ...)
    if self:complete() then
        self.queue[self] = nil
    end
    if not success then
        status('Task', 'task failed: %s', result)
    end
end

function M:execute(command, args, input)
    local use_tty = input == nil
    if use_tty then
        suspend_tty()
    end
    snowcone.execute(command, args or {},
    function(...)
        if use_tty then
            resume_tty()
        end
        self:resume(...)
    end, input)
    return coroutine.yield()
end


return M
