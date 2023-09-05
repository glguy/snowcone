local class = require 'pl.class'

local M = class()
M._name = 'Task'

function M:_init(main, ...)
    self.co = coroutine.create(main)
    local success, result = coroutine.resume(self.co, self, ...)
    if not success then
        status('Task', 'startup failed: %s', result)
    elseif not self:complete() then
        tasks[self] = true
    end
end

function M:wait_for_command(command_set)
    self.want_command = command_set
    return coroutine.yield()
end

function M:complete()
    return coroutine.status(self.co) == 'dead'
end

function M:resume_irc(irc)
    self.want_command = nil
    local success, result = coroutine.resume(self.co, irc)
    if not success then
        status('Task', 'resume failed: %s', result)
    end
end

return M