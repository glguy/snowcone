local Task = require 'components.Task'
local cap_negotiation = require 'utils.cap_negotiation'

-- callback functions for the CAP subcommands
local CAP = {}

function CAP.DEL(capsarg)
    irc_state:del_caps(capsarg)
end

function CAP.NEW(capsarg)
    local new_caps = irc_state:add_caps(capsarg)

    local req = {}

    for cap, _ in pairs(irc_state.caps_wanted) do
        if nil ~= new_caps[cap] and not irc_state.caps_enabled[cap] then
            table.insert(req, cap)
        end
    end
    if next(req) then
        Task('cap negotiation', irc_state.tasks, cap_negotiation.REQ, req)
    end
end

return CAP
