-- What an IRC line's parameters can hold. Every parameter but the last is
-- a word: not empty, without a space and not starting with ":", which
-- would begin the last. The last can be anything else, sent after a ":".
-- None can hold a NUL, CR or LF, which would end the line.

local M = {}

--- Whether a parameter can go before a line's last one.
---@param part string
---@return boolean
function M.middle(part)
    return part:find '^[^ :][^ ]*$' ~= nil
end

--- Why a word typed for a parameter before the last can't be one.
---@param word string
---@return string
function M.not_middle(word)
    return word .. ' can\'t start with ":" before the last parameter'
end

--- Whether a parameter holds a byte no parameter can.
---@param part string
---@return boolean
function M.prohibited(part)
    return part:find '[\0\r\n]' ~= nil
end

return M
