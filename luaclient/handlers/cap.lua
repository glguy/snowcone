local sasl        = require_ 'sasl'
local send        = require 'utils.send'

local CAP = {}

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
                irc_state.caps_requested[cap] = true
                table.insert(req, cap)
            end
        end

        if next(req) then
            send('CAP', 'REQ', table.concat(req, ' '))
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
        irc_state.caps_requested[cap] = nil
        if minus == '-' then
            irc_state.caps_enabled[cap] = nil
        else
            irc_state.caps_enabled[cap] = true
        end
    end

    -- once all the requested caps have been ACKd clear up the request
    if not next(irc_state.caps_requested) then
        if irc_state.caps_enabled.sasl and irc_state.want_sasl then
            irc_state.want_sasl = nil
            sasl.start()
        elseif irc_state.phase == 'registration' then
            send('CAP', 'END')
        end
    end
end

function CAP.NAK(capsarg)
    for cap in capsarg:gmatch '[^ ]+' do
        irc_state.caps_requested[cap] = nil
    end
    status('cap', "caps nak'd: %s", capsarg)
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
            irc_state.caps_requested[cap] = true
            table.insert(req, cap)
        end
        if next(req) then
            send('CAP', 'REQ', table.concat(req, ' '))
        end
    end
end

return CAP
