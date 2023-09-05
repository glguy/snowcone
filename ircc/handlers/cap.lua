local sasl = require_ 'sasl'
local send = require 'utils.send'
local Task = require 'components.Task'
local Set  = require 'pl.Set'

-- callback functions for the CAP subcommands
local CAP = {}

local function request_caps(request)
    Task(irc_state.tasks, function(self)
        local outstanding = Set(request)
        send('CAP', 'REQ', table.concat(request, ' '))

        while not Set.isempty(outstanding) do
            local irc = self:wait_irc(Set{"CAP"})
            local subcommand = irc[2]
            local caps = irc[3]

            -- CAP * <ACK|NAK> :x y z
            if subcommand == "ACK" then
                for minus, cap in caps:gmatch '(%-?)([^ ]+)' do
                    outstanding[minus .. cap] = nil
                    irc_state.caps_enabled[cap] = minus == '' or nil
                end
            elseif subcommand == "NAK" then
                for cap in caps:gmatch '[^ ]+' do
                    outstanding[cap] = nil
                end
                status('cap', "caps nak'd: %s", capsarg)
            end
        end

        if irc_state:has_sasl() and irc_state.sasl_credentials then
            local credentials = irc_state.sasl_credentials
            irc_state.sasl_credentials = nil
            -- transfer directly into sasl task body
            sasl(self, credentials, irc_state.phase == 'registration')
        end
        if irc_state.phase == 'registration' then
            send('CAP', 'END')
        end
    end)
end

local function check_end_of_req()
    -- once all the requested caps have been ACKd clear up the request
    
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

-- Just report the outcome into the /status window
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
