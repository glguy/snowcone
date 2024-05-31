local M = {}

function M.pretty_duration(duration)
    local m = math.tointeger(duration)
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

function M.pretty_seconds(s)
    local d, h, m
    m, s = s // 60, s % 60
    h, m = m // 60, m % 60
    d, h = h // 24, h % 24

    if d > 0 then
        return string.format('%dd %02d:%02d:%02d', d, h, m, s)
    else
        return string.format('%02d:%02d:%02d', h, m, s)
    end
end

return M
