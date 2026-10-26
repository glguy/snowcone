-- Synchronous publish and subscribe.
--
-- Each generation builds its own bus; subscriptions are never persisted.
-- Every topic emitted with a literal name MUST be listed in hub/EVENTS.md.

local dispatch <const> = require 'hub.runtime.dispatch'

local M = {}

local max_depth <const> = 32

---@return table a new, empty bus
function M.new()
    return {topics = {}, depth = 0}
end

--- Subscribe to a topic. Subscribers run in the order they subscribed.
---@param b table bus
---@param topic string
---@param owner string module or plugin, for error reports
---@param fn function called with the event table
function M.on(b, topic, owner, fn)
    local subs = b.topics[topic]
    if subs == nil then
        subs = {}
        b.topics[topic] = subs
    end
    table.insert(subs, {owner = owner, fn = fn})
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

--- Deliver an event on the current generation's bus, then to tasks
--- waiting for it. Before the first generation is active there is no bus
--- and the event is dropped.
---@param topic string
---@param ev table
function M.emit(topic, ev)
    local current = HUB.current
    if current then
        M.emit_on(current.bus, topic, ev)
        -- a route, since runtime/task requires this module
        local deliver = current.routes['task.event']
        if deliver then deliver(topic, ev) end
    end
end

return M
