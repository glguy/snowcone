local rex = require 'rex_pcre2'

local M = {}

local cached_pat
local cached_obj

function M.compile(pat)
    local insensitive = not pat:find '%u'
    local flag
    if insensitive then flag = 'i' end

    local success, output = pcall(rex.new, pat, flag)
    if success then
        return output
    end
end

function M.safematch(str, pat)

    if type(pat) == string then
        if pat ~= cached_pat then
            local output = M.compile(pat)
            if output then
                cached_obj = output
                cached_pat = pat
                pat = output
            else
                cached_pat = nil
                cached_obj = nil
                pat = nil
            end
        else
            pat = cached_obj
        end
    end

    if not pat then return true end

    local success, result = pcall(pat.exec, pat, str)
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