-- Event rates, as records and functions.
--
-- An average holds 1, 5 and 15 minute exponential moving averages of a
-- per-second count and the last 60 samples. A tracker counts events by
-- name during a second; sampling it once a second feeds one average per
-- name and a global one.

local M = {}

local exp = {}
for i = 1, 15 do
    exp[i] = 1 / math.exp(1 / i / 60)
end

local ticks <const> = {[0] = ' ', '▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'}

--- Exponentially damped averages over 1, 5 and 15 minutes of one count a
--- second, and the last 60 counts.
---@class hub.LoadAverage
---@field kind 'LoadAverage'
---@field [1] number
---@field [5] number
---@field [15] number
---@field recent integer[] the last 60 samples, a ring indexed by n
---@field n integer samples so far

---@return hub.LoadAverage
function M.new_average()
    return {kind = 'LoadAverage', [1] = 0, [5] = 0, [15] = 0, recent = {}, n = 0}
end

--- Add one second's count.
function M.sample(avg, x)
    -- averages warm up: until 5 or 15 minutes have passed, use what there is
    local mins = math.max(1, math.ceil(avg.n / 60))
    local exp_1 = exp[1]
    local exp_5 = exp[math.min(5, mins)]
    local exp_15 = exp[math.min(15, mins)]

    avg[1] = avg[1] * exp_1 + x * (1 - exp_1)
    avg[5] = avg[5] * exp_5 + x * (1 - exp_5)
    avg[15] = avg[15] * exp_15 + x * (1 - exp_15)
    avg.recent[avg.n % 60 + 1] = x
    avg.n = avg.n + 1
end

--- The last 60 samples as a bar graph, newest first.
---@param avg hub.LoadAverage
---@return string
function M.graph(avg)
    local output = {}
    local j = 1
    local start = (avg.n - 1) % 60 + 1
    for i = start, 1, -1 do
        output[j] = ticks[math.min(8, avg.recent[i] or 0)]
        j = j + 1
    end
    for i = 60, start + 1, -1 do
        output[j] = ticks[math.min(8, avg.recent[i] or 0)]
        j = j + 1
    end
    return table.concat(output)
end

--- Load averages of named events, and of all of them.
---@class hub.LoadTracker
---@field kind 'LoadTracker'
---@field events table<string, integer> counts in the current second
---@field global hub.LoadAverage
---@field detail table<string, hub.LoadAverage> by name

---@return hub.LoadTracker
function M.new_tracker()
    return {kind = 'LoadTracker', events = {}, global = M.new_average(), detail = {}}
end

--- Count n (default 1) events for a name in the current second. A count
--- of 0 makes the name known, so it is graphed from now on.
function M.track(tracker, name, n)
    tracker.events[name] = (tracker.events[name] or 0) + (n or 1)
end

--- End the current second.
function M.tick(tracker)
    for name in pairs(tracker.events) do
        if not tracker.detail[name] then
            tracker.detail[name] = M.new_average()
        end
    end
    local total = 0
    for name, avg in pairs(tracker.detail) do
        local n = tracker.events[name] or 0
        M.sample(avg, n)
        total = total + n
    end
    tracker.events = {}
    M.sample(tracker.global, total)
end

return M
