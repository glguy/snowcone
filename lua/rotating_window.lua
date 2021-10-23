local M = {}

function M.build_window(source, rows, predicate)
    if rows <= 0 then return {} end

    local n = 0
    local offset = 0
    local window = {}
    local beginning = true

    for _, entry in source:each(scroll) do
        if n+1 >= rows then break end -- saves a row for divider
        if not predicate or predicate(entry) then
            beginning = false
            window[(source.n-offset-1-n) % rows + 1] = entry
            n = n + 1
        elseif beginning then
            offset = offset + 1
        end
    end

    window[(source.n-offset) % rows + 1] = 'divider'
    return window
end

return M
