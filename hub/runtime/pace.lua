-- How often inbound messages redraw the screen.
--
-- A message draws at the end of its read when the screen hasn't been
-- drawn for an interval; otherwise a timer draws once the interval is
-- over. Anything else that changes the screen (a key, a timer) still
-- draws at once, with every message so far.

local clock     <const> = require 'hub.runtime.clock'
local dispatch  <const> = require 'hub.runtime.dispatch'
local resources <const> = require 'hub.runtime.resources'
local timer     <const> = require 'hub.runtime.timer'

local M = {}

M.interval = 0.1 -- seconds

--- Hold the draw at the end of this native callback until it is due.
function M.hold()
    -- nothing draws without a UI
    if not HUB.current.routes['ui.draw'] then return end
    local id = HUB.draw_timer
    if not (id and resources.get(id)) then
        local last = HUB.drawn_at
        local wait = last and last + M.interval - clock.now() or 0
        if wait <= 0 then return end
        HUB.draw_timer = timer.start('pace', math.ceil(wait * 1000), 'pace.due')
    end
    dispatch.defer_draw()
end

M.routes = {
    -- leaving this callback draws
    ['pace.due'] = function() end,
}

return M
