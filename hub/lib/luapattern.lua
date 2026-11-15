-- Checking a Lua pattern before it is used. Lua parses a pattern only as
-- far as a match gets, so one that is malformed past its first item
-- passes a trial match and raises later, on the text that reaches the
-- fault. This walks the whole pattern the way Lua's matcher reads it
-- (lstrlib.c) and reports what Lua would.

local M = {}

-- Lua's LUA_MAXCAPTURES
local max_captures <const> = 32

-- The position after a set starting at `i` (its '['), or nil and why
local function set_end(p, i)
    local n = #p
    local j = i + 1
    if p:sub(j, j) == '^' then j = j + 1 end
    -- the first character is in the set even when it is ']'
    repeat
        if j > n then return nil, "malformed pattern (missing ']')" end
        local c = p:sub(j, j)
        j = j + 1
        if c == '%' and j <= n then j = j + 1 end
    until p:sub(j, j) == ']'
    return j + 1
end

--- Why a Lua pattern can't be used, as Lua would say it, or nil when it
--- can.
---@param p string
---@return string|nil
function M.check(p)
    local n = #p
    local i = p:sub(1, 1) == '^' and 2 or 1
    local open = {}   -- captures still open, innermost last
    local closed = {} -- [index] = true once closed
    local count = 0
    while i <= n do
        local c = p:sub(i, i)
        if c == '(' then
            count = count + 1
            if count > max_captures then return 'too many captures' end
            if p:sub(i + 1, i + 1) == ')' then
                -- a position capture
                closed[count] = true
                i = i + 2
            else
                table.insert(open, count)
                i = i + 1
            end
        elseif c == ')' then
            if #open == 0 then return 'invalid pattern capture' end
            closed[table.remove(open)] = true
            i = i + 1
        elseif c == '$' and i == n then
            i = i + 1
        else
            local quantified = true
            if c == '%' then
                local e = p:sub(i + 1, i + 1)
                if e == '' then
                    return "malformed pattern (ends with '%')"
                elseif e == 'b' then
                    if i + 3 > n then return 'missing arguments to %b' end
                    i, quantified = i + 4, false
                elseif e == 'f' then
                    if p:sub(i + 2, i + 2) ~= '[' then return "missing '[' after '%f' in pattern" end
                    local after, err = set_end(p, i + 2)
                    if not after then return err end
                    i, quantified = after, false
                elseif e:find '%d' then
                    local index = tonumber(e)
                    if not closed[index] then return 'invalid capture index %' .. e end
                    i, quantified = i + 2, false
                else
                    i = i + 2
                end
            elseif c == '[' then
                local after, err = set_end(p, i)
                if not after then return err end
                i = after
            else
                i = i + 1
            end
            if quantified and p:sub(i, i):find '^[*+?%-]$' then i = i + 1 end
        end
    end
    if #open > 0 then return 'unfinished capture' end
    return nil
end

return M
