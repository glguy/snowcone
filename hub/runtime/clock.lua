-- Wall clock and uptime (design section 4.7).
--
-- Compare times by difference with >=, never by equality with a counter.

local M = {}

--- Seconds since the epoch, with fractions.
---@return number
function M.now()
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
