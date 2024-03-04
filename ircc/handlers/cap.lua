local Task = require 'components.Task'
local cap_negotiation = require 'utils.cap_negotiation'

-- callback functions for the CAP subcommands
local CAP = {}

function CAP.DEL(capsarg)
    for cap in capsarg:gmatch '[^ ]+' do
        irc_state.caps_available[cap] = nil
        irc_state.caps_enabled[cap] = nil
    end
end

function CAP.NEW(capsarg)
    local req = {}
    for cap, eq, arg in capsarg:gmatch '([^ =]+)(=?)([^ ]*)' do
        irc_state.caps_available[cap] = eq == '=' and arg or true
        if irc_state.caps_wanted[cap] and not irc_state.caps_enabled[cap] then
            table.insert(req, cap)
        end
        if 'sasl' == cap then
            irc_state:set_sasl_mechs(arg)
        end
        if next(req) then
            Task('cap negotiation', irc_state.tasks, cap_negotiation.REQ, req)
        end
    end
end

return CAP
