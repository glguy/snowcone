return function(source, rows, predicate)
    source.predicate = predicate
    if rows <= 0 then return {} end

    local n = 0
    local window = {}

    for entry in source:each(scroll) do
        if n+1 >= rows then break end -- saves a row for divider
        if not predicate or predicate(entry) then
            window[(source.ticker-1-n) % rows + 1] = entry
            n = n + 1
        end
    end

    window[source.ticker % rows + 1] = 'divider'
    return window
end
