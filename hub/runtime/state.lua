-- The persistent state root, HUB.state.
--
-- State is plain data that every generation shares. Modules that own a
-- part of it export:
--   init_state(S)          create missing parts; MUST be idempotent and
--                          additive, since it runs on every load
--   migrate(S, from)       reshape data written by an older version; MUST be
--                          safe to run again if a later load step fails
-- State never holds closures, coroutines or metatables with methods.

local M = {}

--- Bump when a migration is needed.
M.VERSION = 1

-- Records that need a metatable get one back from here after every load,
-- by their `kind` field. Nothing needs it yet.
local rebinders <const> = {}

local function rebind(t, seen)
    if seen[t] then return end
    seen[t] = true
    local f = rebinders[t.kind]
    if f then f(t) end
    for _, v in pairs(t) do
        if type(v) == 'table' then
            rebind(v, seen)
        end
    end
end

--- Bring HUB.state up to date for a list of loaded modules.
---@param modules table sequence of {name = string, module = table}, in layer order
function M.prepare(modules)
    local S = HUB.state
    if S == nil then
        S = {version = M.VERSION}
        HUB.state = S
    end

    if S.version > M.VERSION then
        error(string.format('state version %d is newer than this code (%d)', S.version, M.VERSION), 0)
    end

    if S.version < M.VERSION then
        for _, entry in ipairs(modules) do
            local migrate = type(entry.module) == 'table' and entry.module.migrate
            if migrate then
                migrate(S, S.version)
            end
        end
    end

    for _, entry in ipairs(modules) do
        local init_state = type(entry.module) == 'table' and entry.module.init_state
        if init_state then
            init_state(S)
        end
    end

    if next(rebinders) then
        rebind(S, {})
    end
end

--- Record that migrations have been applied, once the generation is current.
function M.commit()
    HUB.state.version = M.VERSION
end

return M
