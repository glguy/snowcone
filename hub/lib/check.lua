-- assert for expected failures, such as bad input from a server or a
-- setting the schema can't rule out: raised at level 0, so it is
-- reported as a message, without a traceback (see lib/traceback.lua).

---@generic T
---@param value T|nil|false
---@param message string
---@return T
return function(value, message)
    if not value then
        error(message, 0)
    end
    return value
end
