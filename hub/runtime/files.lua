-- Files hub writes for the user.

local M = {}

--- Create a file only its owner can read, for private keys. An existing
--- file is an error, so a key is never overwritten.
---@param path string
---@param content string
---@return true|nil
---@return string|nil error
function M.write_private(path, content)
    return snowcone.write_private(path, content)
end

return M
