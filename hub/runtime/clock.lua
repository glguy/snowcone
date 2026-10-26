-- Time for durations and uptime.
--
-- now() is monotonic when the client provides snowcone.monotime, so
-- setting the system clock doesn't disturb timeouts; its zero is then
-- arbitrary, so use it for differences only (and os.time/os.date for
-- the time of day). Compare by difference with >=, never by equality.

local M = {}

local monotime = snowcone.monotime

--- Seconds, with fractions, for measuring durations.
---@return number
function M.now()
    if monotime then
        return monotime()
    end
    local s, ns = snowcone.time()
    return s + ns * 1e-9
end

--- Seconds since the client started.
---@return number
function M.uptime()
    return M.now() - HUB.state.clock.started
end

function M.init_state(S)
    S.clock = S.clock or {}
    S.clock.started = S.clock.started or M.now()
end

return M
