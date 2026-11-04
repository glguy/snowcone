-- Key codes, for the tables of key handlers.
--
-- Keys arrive as integers: a code point, or a negated ncurses KEY_ value
-- for special keys, or a negated character for Meta combinations.

local M = {}

--- The key code of Ctrl and a character
---@param x string
---@return integer
function M.ctrl(x)
    return 0x1f & string.byte(x)
end

--- The key code of Meta and a character
---@param x string
---@return integer
function M.meta(x)
    return -string.byte(x)
end

--- The key code of Meta, Ctrl and a character
---@param x string
---@return integer
function M.meta_ctrl(x)
    return -(0x1f & string.byte(x))
end

return M
