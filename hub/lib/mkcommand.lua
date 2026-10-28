-- Command argument specs, compiled with pl.sip.
--
-- Type      Meaning
-- v         identifier
-- i         possibly signed integer
-- f         floating-point number
-- r         rest of line
-- q         quoted string (quoted using either ' or ")
-- p         a path name
-- (         anything inside balanced parentheses
-- [         anything inside balanced brackets
-- {         anything inside balanced curly brackets
-- <         anything inside balanced angle brackets
--
-- g         any non-empty printable sequence
-- R         rest of line (allowing empty)

local sip <const> = require 'pl.sip'

sip.custom_pattern('g', '(%g+)')
sip.custom_pattern('R', '(.*)')

--- Compile a spec into a matcher: matcher(args, params) fills params and
--- returns true when args fit the spec.
---@param spec string
---@return function
return function(spec)
    if spec == '' then
        return function(args) return args == '' end
    end
    return assert(sip.compile(spec, {at_start = true}))
end
