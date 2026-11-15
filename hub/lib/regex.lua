-- PCRE2 regular expressions, for the settings that take them (such as
-- `mention.regexes`). They need rex_pcre2: a setting that has one fails
-- the load without it, and is never read as a Lua pattern instead. A
-- regular expression matches as written, with no flags; (?i) ignores
-- case. PCRE2's match limit counts as no match.

local has_rex, rex = pcall(require, 'rex_pcre2')

local M = {}

M.available = has_rex

--- Why a regular expression can't be used, or nil when it can.
---@param source string
---@return string|nil
function M.check(source)
    if not has_rex then return 'regular expressions need rex_pcre2' end
    local ok, err = pcall(rex.new, source)
    if not ok then return tostring(err) end
    return nil
end

-- Compiled regular expressions by source, false for one that doesn't
-- compile; only configured ones are compiled, so there are few
local compiled = {}

--- Whether text matches a regular expression. One that can't be used
--- matches nothing.
---@param source string
---@param text string
---@return boolean
function M.find(source, text)
    if not has_rex then return false end
    local re = compiled[source]
    if re == nil then
        local ok, result = pcall(rex.new, source)
        re = ok and result or false
        compiled[source] = re
    end
    if not re then return false end
    local done, found = pcall(re.exec, re, text)
    return done and found ~= nil
end

return M
