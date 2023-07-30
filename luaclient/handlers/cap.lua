local Set         = require 'pl.Set'
local tablex      = require 'pl.tablex'
local sasl        = require_ 'sasl'
local send        = require 'utils.send'

-- install SASL state machine based on configuration values
-- and send the first AUTHENTICATE command
local function start_sasl()
    local success, auth_cmd
    success, auth_cmd, irc_state.sasl = pcall(sasl.start,
        configuration.irc_sasl_mechanism,
        configuration.irc_sasl_username,
        configuration.irc_sasl_password,
        configuration.irc_sasl_key,
        configuration.irc_sasl_authzid
    )
    if success then
        send(table.unpack(auth_cmd))
    else
        status('sasl', 'startup failed: %s', auth_cmd)
    end
end

local CAP = {}

function CAP.LS(x, y)
    -- CAP * LS * :x y z    -- continuation
    -- CAP * LS :x y z      -- final

    if irc_state.caps_available == nil then
        irc_state.caps_available = Set{}
    end

    local last = x ~= '*'
    local capsarg
    if last then capsarg = x else capsarg = y end
    for cap in capsarg:gmatch '([^ =]+)(=?)([^ ]*)' do
        irc_state.caps_available[cap] = true
    end

    if last then
        if irc_state.caps_wanted ~= nil and not Set.isempty(irc_state.caps_wanted) then
            local missing = Set.difference(irc_state.caps_wanted, irc_state.caps_available)
            if Set.isempty(missing) then
                send('CAP', 'REQ', table.concat(tablex.keys(irc_state.caps_wanted), ' '))
            else
                status('cap', 'caps not available: ' .. table.concat(Set.values(missing), ', '))
            end
        end
        irc_state.caps_available = nil
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
    for minus, cap in capsarg:gmatch '(%-?)([^ =]+)' do
        if irc_state.caps_wanted ~= nil then
            irc_state.caps_wanted[cap] = nil
        end
        if minus == '-' then
            irc_state.caps_enabled[cap] = nil
        else
            irc_state.caps_enabled[cap] = true
        end
    end

    -- once all the requested caps have been ACKd clear up the request
    if irc_state.caps_wanted ~= nil and Set.isempty(irc_state.caps_wanted) then
        irc_state.caps_wanted = nil
        if irc_state.caps_enabled.sasl and irc_state.want_sasl then
            irc_state.want_sasl = nil
            start_sasl()
        else
            if irc_state.registration then
                send('CAP', 'END')
            end
        end
    end
end

function CAP.NAK(capsarg)
    status('cap', "caps nak'd: %s", capsarg)
end

function CAP.DEL(capsarg)
    for cap in capsarg:gmatch '[^ ]+' do
        irc_state.caps_enabled[cap] = nil
    end
end

return CAP