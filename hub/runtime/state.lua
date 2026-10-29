-- The persistent state root, HUB.state.
--
-- State is plain data that every generation shares. A module that owns a
-- part of it exports init_state(S), which creates missing parts. It runs on
-- every load, so it MUST be idempotent and only add: a reload never
-- reshapes existing data. State never holds closures, coroutines or
-- metatables with methods.

local M = {}

--- HUB.state, as the modules' init_state functions make it.
---@class hub.State
---@field nets table<string, hub.Network> by network id (net/manager.lua)
---@field config table|nil the active, normalized configuration
---@field features hub.Features
---@field console_all hub.OrderedMap every network's traffic, interleaved
--- (net/send.lua)
---@field log hub.OrderedMap of hub.LogEntry
---@field log_last string|false the last log line, until dismissed
---@field clock {started: number}
---@field ui hub.UiState (ui/control.lua)

--- Each feature's state. Per-network state is by network id
--- (features/common.lua).
---@class hub.Features
---@field chat table<string, hub.ChatState>|nil
---@field oper table<string, hub.OperState>|nil
---@field snotice table<string, hub.Stores>|nil
---@field topology table<string, hub.Topology>|nil
---@field topology_meta {timer: integer|nil}|nil the rotation refresh timer
---@field notify hub.NotifyState
---@field plugins table<string, table> each plugin's api.state, by name
---@field [string] table

--- Bring HUB.state up to date for a list of loaded modules.
---@param modules {name: string, module: any}[] in layer order
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
