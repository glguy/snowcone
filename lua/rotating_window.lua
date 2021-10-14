local M = {}

function M.build_window(source, method, rows)

    if rows <= 0 then return {} end

    local n = 0
    local window = {}

    for _, entry in source[method](source) do
        if n+1 >= rows then break end -- saves a row for divider
        window[(source.n-1-n) % rows + 1] = entry
        n = n + 1
    end
    window[source.n % rows + 1] = 'divider'
    return window
end

return M
