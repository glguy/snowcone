-- The persistent state root, HUB.state.
--
-- State is plain data that every generation shares. A module that owns a
-- part of it exports init_state(S), which creates missing parts. It runs on
-- every load, so it MUST be idempotent and only add: a reload never
-- reshapes existing data. State never holds closures, coroutines or
-- metatables with methods.

local M = {}

--- Bring HUB.state up to date for a list of loaded modules.
---@param modules table sequence of {name = string, module = table}, in layer order
function M.prepare(modules)
    HUB.state = HUB.state or {}
    for _, entry in ipairs(modules) do
        local init_state = type(entry.module) == 'table' and entry.module.init_state
        if init_state then
            init_state(HUB.state)
        end
    end
end

return M
