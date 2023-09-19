local M = {}

function M.safematch(str, pat, insensitive)
    if insensitive then str = str:lower() end
    local success, result = pcall(string.match, str, pat)
    return not success or result
end

local function is_case_insensitive_pattern(pat)
    pat = pat:gsub('%%.', '')
    return pat == pat:lower()
end

function M.current_pattern()
    local current_filter
    if input_mode == 'filter' then
        current_filter = editor:content()
    else
        current_filter = filter
    end
    local insensitive = current_filter and is_case_insensitive_pattern(current_filter)
    return current_filter, insensitive
end

return M