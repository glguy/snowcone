local function parse(str)
    local tags, str1 = string.match(str, '^@(%g*) (.*)$')
    if tags then str = str1 end

    local source, str1 = string.match(str, '^:(%g*) (.*)')
    if source then str = str1 end

    local n = 0
    local args = {}
    while true do
        local arg, str1 = string.match()
    end

    return tags
end

return parse
