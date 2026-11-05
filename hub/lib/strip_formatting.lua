local hex6 <const> = string.rep('%x', 6)

--- The text without its IRC formatting: the color codes and their
--- parameters, and the style codes. Other control characters stay.
---@param str string
---@return string
return function(str)
    local out, i = {}, 1
    while i <= #str do
        local at = str:find('[\x02\x03\x04\x0f\x11\x16\x1d\x1e\x1f]', i)
        if at == nil then
            table.insert(out, str:sub(i))
            break
        end
        table.insert(out, str:sub(i, at - 1))
        local ctrl = str:sub(at, at)
        i = at + 1
        if ctrl == '\x03' then
            i = str:match('^%d%d?,%d%d?()', i) or str:match('^%d?%d?()', i)
        elseif ctrl == '\x04' then
            i = str:match('^' .. hex6 .. ',' .. hex6 .. '()', i) or str:match('^' .. hex6 .. '()', i) or i
        end
    end
    return table.concat(out)
end
