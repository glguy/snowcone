-- IRC case mappings, by the names ISUPPORT CASEMAPPING uses.
--
-- State refers to a mapping by name, never by function, so it survives a
-- reload.

local M = {}

local function ascii(s)
    return (string.gsub(s, '[a-z]', string.upper))
end

local strict_map <const> = {['{'] = '[', ['}'] = ']', ['|'] = '\\'}
local function rfc1459_strict(s)
    return (string.gsub(s, '[a-z{}|]', function(c)
        return strict_map[c] or string.upper(c)
    end))
end

M.mappings = {
    ['ascii'] = ascii,
    ['rfc1459'] = snowcone.irccase,
    ['rfc1459-strict'] = rfc1459_strict,
}

--- Find a mapping by name. Unknown names fall back to rfc1459, the IRC default.
---@param name string|nil
---@return fun(s: string): string
function M.get(name)
    return M.mappings[name] or snowcone.irccase
end

--- Normalize a string under the named mapping.
---@param name string|nil
---@param s string
---@return string
function M.fold(name, s)
    return M.get(name)(s)
end

return M
