-- A key that orders IP addresses: IPv4 before IPv6, each by its value.
-- The key is in lowercase hex, 04 or 06 and then the address; nil for text
-- that isn't an address.

local function ipv4(text)
    local out = {}
    for part in (text .. '.'):gmatch '([^.]*)%.' do
        local n = part:match '^%d%d?%d?$' and tonumber(part)
        if not n or n > 255 then return end
        table.insert(out, string.format('%02x', n))
    end
    if #out == 4 then return table.concat(out) end
end

-- The groups of colon-separated text, a list of 4 hex digits each
local function groups(text)
    local out = {}
    if text == '' then return out end
    for part in (text .. ':'):gmatch '([^:]*):' do
        if not part:match '^%x%x?%x?%x?$' then return end
        table.insert(out, string.rep('0', 4 - #part) .. part:lower())
    end
    return out
end

local function ipv6(text)
    -- an IPv4 address may be the last two groups
    local before, last = text:match '^(.*:)([%d.]+)$'
    if last and last:find('.', 1, true) then
        local v4 = ipv4(last)
        if not v4 then return end
        text = before .. v4:sub(1, 4) .. ':' .. v4:sub(5)
    end

    local left, right = text:match '^(.-)::(.*)$'
    local head = groups(left or text)
    local tail = groups(right or '')
    if not head or not tail then return end
    local missing = 8 - #head - #tail
    if left and missing < 1 or not left and missing ~= 0 then return end
    return table.concat(head) .. string.rep('0000', missing) .. table.concat(tail)
end

---@param text string
---@return string|nil
return function(text)
    if text:find(':', 1, true) then
        local key = ipv6(text)
        return key and '06' .. key
    end
    local key = ipv4(text)
    return key and '04' .. key
end
