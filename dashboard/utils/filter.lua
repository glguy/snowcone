local rex = require 'rex_pcre2'

local M = {}

local cached_pat
local obj

function M.safematch(str, pat)

    if pat ~= cached_pat then
        local insensitive = not pat:find '%u'
        local flag
        if insensitive then flag = 'i' end

        local success, output = pcall(rex.new, pat, flag)
        if success then
            obj = output
            cached_pat = pat
        else
            cached_pat = nil
            obj = nil
        end
    end

    if not obj then return true end

    local success, result = pcall(obj.exec, obj, str)
    return not success or result
end

function M.current_pattern()
    if input_mode == 'filter' then
        return editor:content()
    else
        return filter
    end
end

return M