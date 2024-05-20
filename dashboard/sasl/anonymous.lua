-- Anonymous Simple Authentication and Security Layer (SASL) Mechanism
-- https://www.rfc-editor.org/rfc/rfc4505.html

return function(trace)
    if mystringprep then
        trace = mystringprep.prep(trace, 'trace')
    end

    return coroutine.create(function()
        return trace
    end)
end
