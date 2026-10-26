-- Synchronous publish and subscribe (design section 4.3).
--
-- Each generation builds its own bus; subscriptions are never persisted.
-- Every topic emitted with a literal name MUST be listed in hub/EVENTS.md.

local dispatch <const> = require 'hub.runtime.dispatch'

local M = {}

local max_depth <const> = 32

---@return table a new, empty bus
function M.new()
    return {topics = {}, depth = 0, seq = 0}
end

--- Subscribe to a topic.
---@param b table bus
---@param topic string
---@param owner string module or plugin, for error reports and off_owner
---@param fn function called with the event table
---@param opts table|nil {priority = number}, lower runs first, default 50
function M.on(b, topic, owner, fn, opts)
    local subs = b.topics[topic]
    if subs == nil then
        subs = {}
        b.topics[topic] = subs
    end
    b.seq = b.seq + 1
    table.insert(subs, {
        owner = owner,
        fn = fn,
        priority = opts and opts.priority or 50,
        seq = b.seq,
    })
    -- stable for equal priorities: subscription order breaks ties
    table.sort(subs, function(x, y)
        if x.priority ~= y.priority then
            return x.priority < y.priority
        end
        return x.seq < y.seq
    end)
end

--- Remove every subscription an owner made.
function M.off_owner(b, owner)
    for topic, subs in pairs(b.topics) do
        local kept = {}
        for _, sub in ipairs(subs) do
            if sub.owner ~= owner then
                table.insert(kept, sub)
            end
        end
        b.topics[topic] = kept
    end
end

--- Deliver an event on a particular bus.
function M.emit_on(b, topic, ev)
    local subs = b.topics[topic]
    if subs == nil then return end

    if b.depth >= max_depth then
        dispatch.report('bus', 'dropped ' .. topic .. ': emit nested too deeply')
        return
    end

    b.depth = b.depth + 1
    -- a snapshot, so subscribing during delivery doesn't disturb it
    for _, sub in ipairs(table.move(subs, 1, #subs, 1, {})) do
        local ok, err = xpcall(sub.fn, debug.traceback, ev)
        if not ok then
            -- restored first so a strict re-raise leaves the bus usable
            b.depth = b.depth - 1
            dispatch.report(topic .. ' (' .. sub.owner .. ')', err)
            b.depth = b.depth + 1
        end
    end
    b.depth = b.depth - 1
end

--- Deliver an event on the current generation's bus. Before the first
--- generation is active there is no bus and the event is dropped.
---@param topic string
---@param ev table
function M.emit(topic, ev)
    local current = HUB.current
    if current then
        M.emit_on(current.bus, topic, ev)
    end
end

return M
