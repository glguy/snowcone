-- One-shot timers that are held as resources and fire through a route.
--
-- A timer started before a reload fires into the code that is current when
-- it fires, because its callback is a trampoline. Repeat by starting a new
-- timer from the route.

local dispatch  <const> = require 'hub.runtime.dispatch'
local resources <const> = require 'hub.runtime.resources'

local M = {}

--- Start a timer that calls route(...) after ms milliseconds.
---@param owner string
---@param ms integer
---@param route string
---@param ... string|number|boolean|nil passed to the route
---@return integer # resource id, for cancel
function M.start(owner, ms, route, ...)
    local t = snowcone.newtimer()
    local id = resources.add('timer', owner, t, 'cancel')
    t:start(ms, dispatch.trampoline('runtime.timer', id, route, ...))
    return id
end

--- Cancel a pending timer. Ids of timers that already fired are ignored.
function M.cancel(id)
    resources.close(id)
end

M.routes = {
    ['runtime.timer'] = function(id, route, ...)
        resources.remove(id)
        dispatch.route(route)(...)
    end,
}

return M
