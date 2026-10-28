-- A bounded map that remembers insertion order and drops the oldest entry
-- when full. It is a plain record plus functions, so a map in HUB.state
-- works the same after a reload.
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
        n = 0,
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
    local m = om.max
    local n = om.n
    local i = n % m + 1
    om.n = n + 1

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
    return math.min(om.n, om.max)
end

function M.get_oldest(om)
    if om.n <= om.max then
        return om.vals[1]
    else
        return om.vals[om.n % om.max + 1]
    end
end

--- Iterate newest first, skipping the newest `offset` entries: val, key
function M.each(om, offset)
    local i = offset or 0
    local n = om.n
    local m = om.max
    local t = math.min(n, m)
    return function()
        if i < t then
            i = i + 1
            local j = (n - i) % m + 1
            return om.vals[j], om.keys[j]
        end
    end
end

--- Iterate oldest first: val, key
function M.reveach(om)
    local i = 0
    local n = om.n
    local t = math.min(n, om.max)
    return function()
        if i < t then
            local j = (n + i) % t + 1
            i = i + 1
            return om.vals[j], om.keys[j]
        end
    end
end

--- Remove every entry, keeping the capacity and casemapping.
function M.reset(om)
    om.index = {}
    om.keys = {}
    om.vals = {}
    om.n = 0
    om.ticker = 0
end

return M
