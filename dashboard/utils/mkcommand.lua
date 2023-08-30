local sip = require 'pl.sip'

--[[
Type      Meaning
v         identifier
i         possibly signed integer
f         floating-point number
r         rest of line
q         quoted string (quoted using either ' or ")
p         a path name
(         anything inside balanced parentheses
[         anything inside balanced brackets
{         anything inside balanced curly brackets
<         anything inside balanced angle brackets

g         any non-empty printable sequence
R         rest of line (allowing empty)
]]

sip.custom_pattern('g', '(%g+)')
sip.custom_pattern('R', '(.*)')

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
