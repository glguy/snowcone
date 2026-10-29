-- Pacing for outgoing lines, as RFC 1459 section 8.10 describes it.
--
-- The bucket is a single time. It is never behind now: idle time refills
-- the burst, but never beyond it. Each line moves it one interval ahead,
-- and a line may go while it is at most burst - 1 intervals ahead of now.
-- So burst lines go at once, then one more each interval.

local M = {}

--- Seconds until the next line may go; 0 when it may go now.
---@param t number the bucket's time
---@param now number
---@param burst integer lines that may go at once
---@param interval number seconds to earn back one line
---@return number
function M.wait(t, now, burst, interval)
    return math.max(0, t - now - (burst - 1) * interval)
end

--- The bucket's time after a line goes at now.
function M.take(t, now, interval)
    return math.max(t, now) + interval
end

return M
