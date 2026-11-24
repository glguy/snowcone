-- Reading TESTMASK's count of the users a mask matches, as the network's
-- ircd gives it.

local ircd <const> = require 'hub.net.ircd'
local N    <const> = require 'hub.lib.numerics'
local NH   <const> = require 'hub.lib.numerics_hybrid'

local M = {}

--- The users a TESTMASK reply counts, and the user@host mask it counted,
--- or nil for another reply. Solanum's has a nick and a realname too:
--- "<client> <local> <remote> <nick>!<user@host> <realname> :..." where
--- hybrid's is "<client> <user@host> <local> <remote> :...".
---@param net string
---@param msg hub.Message
---@return integer|nil, string|nil
function M.count(net, msg)
    local loc, rem, mask
    if ircd.hybrid(net) then
        if msg.command ~= NH.RPL_TESTMASK then return nil end
        mask, loc, rem = msg[2], msg[3], msg[4]
    else
        if msg.command ~= N.RPL_TESTMASKGECOS or msg[5] ~= '*' then return nil end
        loc, rem = msg[2], msg[3]
        mask = msg[4] and msg[4]:match '^%*!(.*)$'
    end
    if not mask then return nil end
    return (math.tointeger(loc) or 0) + (math.tointeger(rem) or 0), mask
end

--- The numeric of a network's TESTMASK count.
function M.numeric(net)
    return ircd.hybrid(net) and NH.RPL_TESTMASK or N.RPL_TESTMASKGECOS
end

return M
