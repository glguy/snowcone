-- Shared helpers for features.
--
-- A feature keeps per-network state in HUB.state.features[name][net],
-- created on first use and dropped when the network is removed.

local M = {}

function M.init_state(S)
    S.features = S.features or {}
end

--- A network has the feature enabled in its configuration.
---@param net string network id
---@param feature string
---@return boolean
function M.enabled(net, feature)
    local rec = HUB.state.nets[net]
    return rec ~= nil and rec.cfg.features[feature] == true
end

--- The network's servers file (runtime/config.lua), or its defaults.
---@param net string network id
---@return table|nil # nil for an unknown network
function M.servers(net)
    local rec = HUB.state.nets[net]
    return rec and rec.cfg.servers
end

--- The feature's state for a network, made by init(rec) on first use.
---@param feature string
---@param net string network id
---@param init fun(rec: hub.Network): table
---@return table
function M.net_state(feature, net, init)
    local all = HUB.state.features[feature]
    if all == nil then
        all = {}
        HUB.state.features[feature] = all
    end
    local s = all[net]
    if s == nil then
        s = init(HUB.state.nets[net])
        all[net] = s
    end
    return s
end

--- The feature's state for a network if it exists.
function M.get_state(feature, net)
    local all = HUB.state.features[feature]
    return all and all[net]
end

--- Forget a removed network's state of the feature.
function M.drop_state(feature, net)
    local all = HUB.state.features[feature]
    if all then all[net] = nil end
end

return M
