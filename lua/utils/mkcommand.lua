local sip = require 'pl.sip'

return function(spec, func)
    local pattern
    if spec == '' then
        pattern = function(args) return args == '' end
    else
        pattern = assert(sip.compile(spec, {at_start=true}))
    end

    return {
        spec = spec,
        pattern = pattern,
        func = func,
    }
end
