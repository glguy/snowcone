-- The server software a network runs, from its `ircd` setting: Solanum
-- or OFTC hybrid. Their numerics, server notices, CHALLENGE and the
-- modes that choose notices differ; each feature asks here which to use.

local numerics        <const> = require 'hub.lib.numerics'
local numerics_hybrid <const> = require 'hub.lib.numerics_hybrid'

local M = {}

M.SOLANUM = 'solanum'
M.HYBRID = 'oftc-hybrid'

--- A network's ircd; Solanum for a network that isn't configured.
---@param net string|nil
---@return string
function M.of(net)
    local rec = net and HUB.state.nets[net]
    return rec and rec.cfg.ircd or M.SOLANUM
end

--- The network runs OFTC hybrid.
---@param net string|nil
function M.hybrid(net)
    return M.of(net) == M.HYBRID
end

local by_ircd <const> = {
    [M.SOLANUM] = numerics,
    [M.HYBRID] = numerics_hybrid,
}

local names_by_ircd <const> = {}
for ircd, t in pairs(by_ircd) do
    local names = {}
    for name, n in pairs(t) do names[n] = name end
    names_by_ircd[ircd] = names
end

--- The name of a numeric on a network, or nil.
---@param net string|nil
---@param command string|integer
---@return string|nil
function M.numeric_name(net, command)
    return names_by_ircd[M.of(net)][command]
end

return M
