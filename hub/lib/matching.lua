-- Filter patterns.
--
-- Patterns are PCRE2 regular expressions when rex_pcre2 is installed, and
-- Lua patterns otherwise. A pattern without capital letters matches
-- without regard to case.

local has_rex, rex = pcall(require, 'rex_pcre2')

local M = {}

M.kind = has_rex and 'pcre2' or 'lua'

--- Compile a pattern into a matcher, or nil when it is invalid.
---@param pat string
---@return (fun(str: string): boolean)|nil
function M.compile(pat)
    local insensitive = not pat:find '%u'
    if has_rex then
        local ok, re = pcall(rex.new, pat, insensitive and 'i' or nil)
        if ok then
            return function(str) return re:exec(str) ~= nil end
        end
        return nil
    end

    if not pcall(string.find, '', pat) then
        return nil
    end
    return function(str)
        if insensitive then str = str:lower() end
        local ok, found = pcall(string.find, str, pat)
        return ok and found ~= nil
    end
end

local cached_pat, cached_matcher

--- Match str against pat. A nil or invalid pattern matches everything.
---@param str string
---@param pat string|nil
---@return boolean
function M.safematch(str, pat)
    if pat == nil then return true end
    if pat ~= cached_pat then
        cached_pat = pat
        cached_matcher = M.compile(pat)
    end
    if not cached_matcher then return true end
    return cached_matcher(str)
end

return M
