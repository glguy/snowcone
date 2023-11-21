local M = {}

function M.pretty_duration(duration)
    local m = tonumber(duration)
    if m then
        if m >= 1440 then
            return string.format('%.1f d', m/1440)
        end
        if m >= 60 then
            return string.format('%.1f h', m/60)
        end
        return duration .. 'm'
    else
        return duration
    end
end

local units = {
    m = 1,
    h = 60,
    d = 1440,
    w = 10080,
    M = 43200,
    Y = 525600,
}

function M.parse_duration(str)
    local acc = 0
    local function f(n, u)
        acc = acc + math.tointeger(n) * units[u]
        return ''
    end
    local leftover = string.gsub(str, ' *(%-?%d+) *([mhdwMY]) *', f)
    if '' == leftover then
        return acc
    end
end

return M
