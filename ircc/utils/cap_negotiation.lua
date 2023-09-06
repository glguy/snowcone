local N = require 'utils.numerics'
local sasl = require_ 'sasl'
local send = require 'utils.send'
local Set  = require 'pl.Set'

local M = {}

local req_commands = Set{'CAP'}

function M.REQ(task, request)
    local outstanding = Set(request)
    send('CAP', 'REQ', table.concat(request, ' '))

    while not Set.isempty(outstanding) do
        local irc = task:wait_irc(req_commands)
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
            status('cap', "caps nak'd: %s", caps)
        end
    end

    if irc_state:has_sasl() and irc_state.sasl_credentials then
        local credentials = irc_state.sasl_credentials
        irc_state.sasl_credentials = nil
        -- transfer directly into sasl task body
        sasl(task, credentials, irc_state.phase == 'registration')
    end
end

local ls_commands = Set{'CAP', N.RPL_WELCOME}

-- Used for the initial capability negotiation during registration
function M.LS(task)
    local caps = {}
    local last = false

    while not last do
        local irc = task:wait_irc(ls_commands)
        if irc.command == 'CAP' and irc[2] == 'LS' then
            -- CAP * LS * :x y z    -- continuation
            -- CAP * LS :x y z      -- final
            local x, y = irc[3], irc[4]
            last = x ~= '*'
            local capsarg
            if last then capsarg = x else capsarg = y end

            for cap, eq, arg in capsarg:gmatch '([^ =]+)(=?)([^ ]*)' do
                caps[cap] = eq == '=' and arg or true
            end
        elseif irc.command == N.RPL_WELCOME then
            return -- welcome means no cap negotiation
        end
    end

    irc_state.caps_available = caps

    local req = {}
    for cap, _ in pairs(caps) do
        if irc_state.caps_wanted[cap] then
            table.insert(req, cap)
        end
    end

    if next(req) then
        M.REQ(task, req)
    end

    send('CAP', 'END')
end

return M