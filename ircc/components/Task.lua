---@alias Set table

local class = require 'pl.class'
local Set = require 'pl.Set'

local empty_set = Set{}

local M = class()
M._name = 'Task'

--- Construct a new Task
---@param name string Name of task
---@param queue table Task queue on an Irc object
---@param main function Implementation body of task
function M:_init(name, queue, main, ...)
    self.name = name
    self.co = coroutine.create(main)
    self.queue = queue
    self.want_command = empty_set
    queue[self] = true
    self:resume(self, ...)
end

function M:__tostring()
    return 'Task: ' .. self.name
end

--- Cancel the wait_irc timer if one is set
function M:cancel_timer()
    local timer = self.timer
    if timer then
        timer.cancel()
        self.timer = nil
    end
end

function M:cancel_dnslookup()
    local dnslookup = self.dnslookup
    if dnslookup then
        dnslookup:cancel()
        self.dnslookup = nil
    end
end

--- Cancel the Task completely
function M:cancel()
    self.queue[self] = nil
    self:cancel_timer()
    self:cancel_dnslookup()
    coroutine.close(self)
end

--- suspend the Task waiting for an IRC command
---@param command_set Set Resume on any of these commands
---@param timeout (nil | integer) milliseconds
function M:wait_irc(command_set, timeout)
    if timeout then
        local timer = snowcone.newtimer()
        self.timer = timer
        timer:start(timeout, function()
            self.timer = nil
            self:resume_irc(nil)
        end)
    end
    self.want_command = command_set
    return coroutine.yield()
end

--- Pause the task
---@param timeout integer milliseconds to sleep
function M:sleep(timeout)
    local timer = snowcone.newtimer()
    self.timer = timer
    timer:start(timeout, function()
        self.timer = nil
        self:resume()
    end)
    return coroutine.yield()
end

function M:dnslookup(name)
    self.dnslookup = snowcone.dnslookup(name, function(...)
        self.dnslookup = nil
        self:resume(...)
    end)
    return coroutine.yield()
end

--- Resume the Task with an IRC object or nil on timeout
---@param irc nil | table
function M:resume_irc(irc)
    self:cancel_timer()
    self.want_command = empty_set
    self:resume(irc)
end

function M:is_complete()
    return coroutine.status(self.co) == 'dead'
end

function M:resume(...)
    local success, result = coroutine.resume(self.co, ...)
    if self:is_complete() then
        self.queue[self] = nil
    end
    if not success then
        status(self.name, '%s', result)
    end
end

return M
