-- A bounded map that remembers insertion order and drops the oldest entry
-- when full. It is a plain record plus functions, so a map in HUB.state
-- works the same after a reload.
--
-- Entries are numbered from 1 in insertion order, and the map holds the
-- numbers first(om) to last(om). A number names the same entry until it
-- is dropped, unless the map pops: pop removes the newest entry and the
-- next insert reuses its number.
--
-- Keys are optional; an entry inserted with a nil key can only be reached
-- by iteration. With a casemapping name, keys are folded before indexing.

local casemap <const> = require 'hub.lib.casemap'

local M = {}

-- Predicates for the ticker, which counts only matching inserts. They are
-- functions, so they can't live in the record; the renderer sets one each
-- frame. Weak keys let a dropped map take its predicate with it.
local predicates <const> = setmetatable({}, {__mode = 'k'})

--- Make an empty map.
---@param max integer capacity
---@param casemapping string|nil name from lib/casemap, for folding keys
---@return table
function M.new(max, casemapping)
    return {
        kind = 'OrderedMap',
        max = max,
        n = 0,      -- number of the newest entry
        lo = 1,     -- number of the oldest entry held
        ticker = 0,
        keys = {},
        vals = {},
        index = {},
        casemapping = casemapping,
    }
end

local function fold(om, key)
    local name = om.casemapping
    if name then
        return casemap.fold(name, key)
    end
    return key
end

-- Where entry k is stored
local function slot(om, k)
    return (k - 1) % om.max + 1
end

local function setindex(om, key, i)
    om.index[fold(om, key)] = i
end

local function getindex(om, key)
    if key == nil then return end
    return om.index[fold(om, key)]
end

--- Count only inserts whose value satisfies p in om.ticker; nil counts all.
function M.set_predicate(om, p)
    predicates[om] = p
end

function M.insert(om, key, val)
    local n = om.n + 1
    local i = slot(om, n)
    om.n = n
    if n - om.lo + 1 > om.max then
        om.lo = om.lo + 1
    end

    -- Overwriting an old entry: remove it from the index if needed
    local old = om.keys[i]
    if old ~= nil and getindex(om, old) == i then
        setindex(om, old, nil)
    end

    if key ~= nil then
        setindex(om, key, i)
    end

    om.keys[i] = key
    om.vals[i] = val

    local p = predicates[om]
    if p == nil or p(val) then
        om.ticker = om.ticker + 1
    end
end

function M.lookup(om, key)
    local i = getindex(om, key)
    return i and om.vals[i]
end

--- Change the key of an entry, keeping its place in the order.
function M.rekey(om, old, new)
    local i = getindex(om, old)
    if i ~= nil then
        setindex(om, old, nil)
        om.keys[i] = new
        setindex(om, new, i)
    end
end

--- Number of entries currently held.
function M.size(om)
    return om.n - om.lo + 1
end

--- Number of the oldest entry held
function M.first(om)
    return om.lo
end

--- Number of the newest entry held, or first(om) - 1 when empty
function M.last(om)
    return om.n
end

--- The entry numbered k, while the map holds it: val, key
function M.get(om, k)
    if om.lo <= k and k <= om.n then
        local i = slot(om, k)
        return om.vals[i], om.keys[i]
    end
end

function M.get_oldest(om)
    return (M.get(om, om.lo))
end

--- Remove the newest entry: val, key
function M.pop(om)
    local n = om.n
    if n < om.lo then return end
    local i = slot(om, n)
    local val, key = om.vals[i], om.keys[i]
    if key ~= nil and getindex(om, key) == i then
        setindex(om, key, nil)
    end
    om.vals[i] = nil
    om.keys[i] = nil
    om.n = n - 1
    return val, key
end

--- Iterate newest first, skipping the newest `offset` entries: val, key
function M.each(om, offset)
    local k = om.n - (offset or 0)
    local lo = om.lo
    return function()
        if lo <= k then
            local i = slot(om, k)
            k = k - 1
            return om.vals[i], om.keys[i]
        end
    end
end

--- Iterate oldest first: val, key
function M.reveach(om)
    local k = om.lo
    local n = om.n
    return function()
        if k <= n then
            local i = slot(om, k)
            k = k + 1
            return om.vals[i], om.keys[i]
        end
    end
end

--- Remove every entry, keeping the capacity and casemapping.
function M.reset(om)
    om.index = {}
    om.keys = {}
    om.vals = {}
    om.n = 0
    om.lo = 1
    om.ticker = 0
end

return M
