local sasl = require_ 'sasl'
local send = require 'utils.send'
local Task = require 'components.Task'

-- callback functions for the CAP subcommands
local CAP = {}

local function request_caps(caps)
    local caps_requested = irc_state.caps_requested
    for _, cap in ipairs(caps) do
        caps_requested[cap] = true
    end
    send('CAP', 'REQ', table.concat(caps, ' '))
end

local function check_end_of_req()
    -- once all the requested caps have been ACKd clear up the request
    if not next(irc_state.caps_requested) then
        if irc_state:has_sasl() and irc_state.sasl_credentials then
            local credentials = irc_state.sasl_credentials
            irc_state.sasl_credentials = nil
            Task(irc_state.tasks, sasl, credentials, irc_state.phase == 'registration')
        elseif irc_state.phase == 'registration' then
            send('CAP', 'END')
        end
    end
end

function CAP.LS(x, y)
    -- CAP * LS * :x y z    -- continuation
    -- CAP * LS :x y z      -- final

    if irc_state.caps_ls == nil then
        irc_state.caps_ls = {}
    end

    local last = x ~= '*'
    local capsarg
    if last then capsarg = x else capsarg = y end
    for cap, eq, arg in capsarg:gmatch '([^ =]+)(=?)([^ ]*)' do
        irc_state.caps_ls[cap] = eq == '=' and arg or true
    end

    if last then
        local available = irc_state.caps_ls
        irc_state.caps_available = available
        irc_state.caps_ls = nil

        local req = {}

        for cap, _ in pairs(available) do
            if irc_state.caps_wanted[cap] and not irc_state.caps_enabled[cap] then
                table.insert(req, cap)
            end
        end

        if next(req) then
            request_caps(req)
        elseif irc_state.phase == 'registration' then
            send('CAP', 'END')
        end
    end
end

function CAP.LIST(x,y)
    if irc_state.caps_list == nil then
        irc_state.caps_list = {}
    end

    local last = x ~= '*'
    local capsarg
    if last then capsarg = x else capsarg = y end
    for cap in capsarg:gmatch '[^ ]+' do
        table.insert(irc_state.caps_list, cap)
    end

    if last then
        status('cap', 'client caps: %s', table.concat(irc_state.caps_list, ', '))
        irc_state.caps_list = nil
    end
end

function CAP.ACK(capsarg)
    for minus, cap in capsarg:gmatch '(%-?)([^ ]+)' do
        irc_state.caps_requested[minus .. cap] = nil
        irc_state.caps_enabled[cap] = minus == '' or nil
    end

    check_end_of_req()
end

function CAP.NAK(capsarg)
    for cap in capsarg:gmatch '[^ ]+' do
        irc_state.caps_requested[cap] = nil
    end
    status('cap', "caps nak'd: %s", capsarg)

    check_end_of_req()
end

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
        if next(req) then
            request_caps(req)
        end
    end
end

return CAP
