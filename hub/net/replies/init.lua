-- What a network's replies mean, by its ircd (net/ircd.lua): the fields
-- of its numerics, and the letters and sigils in them
-- (net/replies/solanum.lua, which documents the fields, and hybrid.lua).

local hybrid  <const> = require 'hub.net.replies.hybrid'
local ircd    <const> = require 'hub.net.ircd'
local solanum <const> = require 'hub.net.replies.solanum'

local M = {}

local by_ircd <const> = {
    [ircd.SOLANUM] = solanum,
    [ircd.HYBRID] = hybrid,
}

--- What a network's replies mean.
---@param net string|nil
function M.of(net)
    return by_ircd[ircd.of(net)]
end

M.address = solanum.address

return M
