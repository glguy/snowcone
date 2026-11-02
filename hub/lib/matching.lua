-- Filter patterns.
--
-- Patterns are PCRE2 regular expressions when rex_pcre2 is installed, and
-- Lua patterns otherwise. A pattern without capital letters matches
-- without regard to case.
--
-- Neither may run away: PCRE2's match limit counts as no match, and Lua
-- patterns, which have no limit, may repeat at most two items with *, +
-- or -, since each more multiplies the work by the subject's length.

local has_rex, rex = pcall(require, 'rex_pcre2')

local M = {}

M.kind = has_rex and 'pcre2' or 'lua'

local max_repeats <const> = 2

-- How many items of a Lua pattern repeat with *, + or -
local function repeats(pat)
    local count, i, n = 0, 1, #pat
    while i <= n do
        local c = pat:sub(i, i)
        local item = true
        if c == '%' then
            local e = pat:sub(i + 1, i + 1)
            if e == 'b' then
                i, item = i + 4, false
            elseif e == 'f' then
                i, item = (pat:find(']', i + 4, true) or n) + 1, false
            else
                i = i + 2
            end
        elseif c == '[' then
            local j = i + 1
            if pat:sub(j, j) == '^' then j = j + 1 end
            if pat:sub(j, j) == ']' then j = j + 1 end
            while j <= n and pat:sub(j, j) ~= ']' do
                j = j + (pat:sub(j, j) == '%' and 2 or 1)
            end
            i = j + 1
        elseif c == '(' or c == ')' then
            i, item = i + 1, false
        else
            i = i + 1
        end
        if item and pat:find('^[*+-]', i) then
            count = count + 1
            i = i + 1
        end
    end
    return count
end

--- Compile a pattern into a matcher, or nil when it is invalid.
---@param pat string
---@return (fun(str: string): boolean)|nil
function M.compile(pat)
    local insensitive = not pat:find '%u'
    if has_rex then
        local ok, re = pcall(rex.new, pat, insensitive and 'i' or nil)
        if ok then
            return function(str)
                local done, found = pcall(re.exec, re, str)
                return done and found ~= nil
            end
        end
        return nil
    end

    if not pcall(string.find, '', pat) or repeats(pat) > max_repeats then
        return nil
    end
    return function(str)
        if insensitive then str = str:lower() end
        local ok, found = pcall(string.find, str, pat)
        return ok and found ~= nil
    end
end

-- Compiled patterns, false for invalid ones; emptied when it fills, so
-- it holds the patterns in use (watches, filters)
local cache, cached = {}, 0
local cache_limit <const> = 256

--- Match str against pat. A nil or invalid pattern matches everything.
---@param str string
---@param pat string|nil
---@return boolean
function M.safematch(str, pat)
    if pat == nil then return true end
    local matcher = cache[pat]
    if matcher == nil then
        if cached >= cache_limit then
            cache, cached = {}, 0
        end
        matcher = M.compile(pat) or false
        cache[pat] = matcher
        cached = cached + 1
    end
    if not matcher then return true end
    return matcher(str)
end

return M
