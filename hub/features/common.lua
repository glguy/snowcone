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

--- Tab's candidates among names: those starting with seed, in any case,
--- sorted.
---@param names string[]
---@param seed string
---@return string[]
function M.starting(names, seed)
    local t = {}
    seed = seed:lower()
    for _, name in ipairs(names) do
        if name:sub(1, #seed):lower() == seed then table.insert(t, name) end
    end
    table.sort(t)
    return t
end

--- How many words come before the one being completed.
---@param before string the arguments before it
---@return integer
function M.words_before(before)
    return select(2, before:gsub('%S+', ''))
end

--- The servers a network is known to have, sorted: its servers file's,
--- and those MAP and LINKS showed while the topology feature runs.
---@param net string network id
---@return string[]
function M.server_names(net)
    local seen = {}
    local cfg = M.servers(net)
    for name in pairs(cfg and cfg.servers or {}) do seen[name] = true end
    local topology = M.enabled(net, 'topology') and M.get_state('topology', net)
    if topology then
        for name in pairs(topology.population) do seen[name] = true end
        for name in pairs(topology.links) do seen[name] = true end
    end
    local t = {}
    for name in pairs(seen) do table.insert(t, name) end
    table.sort(t)
    return t
end

--- Tab's candidates for a server: the network's servers starting with
--- seed.
---@param net string network id
---@param seed string
---@return string[]
function M.complete_server(net, seed)
    return M.starting(M.server_names(net), seed)
end

--- A complete function for a command of one argument: the names
--- names(ctx) gives that start with it, and none past it.
---@param names fun(ctx: hub.CommandContext): string[]
---@return hub.Complete
function M.one_of(names)
    return function(ctx, before, seed)
        if before:find '%S' then return {} end
        return M.starting(names(ctx), seed)
    end
end

--- A complete function for a command whose arguments have no candidates.
---@return string[]
function M.complete_nothing()
    return {}
end

--- A complete function for a command whose first argument the default
--- completes, such as a nick: the default for it, then the names
--- starting with the second, if names are given, and none past them.
---@param names string[]|nil
---@return hub.Complete
function M.default_first(names)
    return function(_, before, seed)
        local n = M.words_before(before)
        if n == 0 then return nil end
        if n == 1 and names then return M.starting(names, seed) end
        return {}
    end
end

--- A complete function offering servers for the argument at index i
--- (from 0), and past it the default when a reason follows, else none.
---@param i integer
---@param reason boolean|nil
---@return hub.Complete
function M.server_at(i, reason)
    return function(ctx, before, seed)
        local n = M.words_before(before)
        if n == i then return M.complete_server(ctx.net, seed) end
        if reason and n > i then return nil end
        return {}
    end
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
--- it: make(name, spec, usage, help, fn, complete) is the command record,
--- complete its Tab's candidates, if any.
---@param feature string
function M.net_command(feature)
    ---@param name string
    ---@param spec string
    ---@param usage string|nil
    ---@param help string
    ---@param fn function
    ---@param complete hub.Complete|nil
    ---@return table
    return function(name, spec, usage, help, fn, complete)
        return {name = name, spec = spec, usage = usage, scope = 'net', feature = feature, help = help, fn = fn,
            complete = complete}
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
