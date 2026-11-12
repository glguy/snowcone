-- Shared helpers for features.
--
-- A feature keeps per-network state in HUB.state.features[name][net],
-- created on first use and dropped when the network is removed.

local log  <const> = require 'hub.runtime.log'
local send <const> = require 'hub.net.send'

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

--- A maker of the feature's commands, which act on a network that has
--- it: make(name, spec, usage, help, fn) is the command record.
---@param feature string
---@return fun(name: string, spec: string, usage: string|nil, help: string, fn: function): table
function M.net_command(feature)
    return function(name, spec, usage, help, fn)
        return {name = name, spec = spec, usage = usage, scope = 'net', feature = feature, help = help, fn = fn}
    end
end

--- A sender for the feature: send(net, command, ...) sends a line
--- (net/send.lua), and when it can't go logs why under the feature's name
--- rather than raising.
---@param feature string
---@return fun(net: string, command: string, ...: string)
function M.sender(feature)
    return function(net, ...)
        local ok, err = pcall(send.send, net, ...)
        if not ok then
            log.add_net(net, feature, '%s', err)
        end
    end
end

--- Forget a removed network's state of the feature.
function M.drop_state(feature, net)
    local all = HUB.state.features[feature]
    if all then all[net] = nil end
end

return M
