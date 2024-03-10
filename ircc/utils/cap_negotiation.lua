local N = require 'utils.numerics'
local sasl = require_ 'sasl'
local send = require 'utils.send'
local Set  = require 'pl.Set'

local M = {}

local req_commands = Set{'CAP'}

-- sends potentially many CAP REQ commands depending on request size
local function send_reqs(request)
    local cursor = 1
    local size = 0
    for i, x in ipairs(request) do
        local n = 1 + #x -- 1 for : or space per req
        size = size + n
        if size > 502 then -- 512 - #'CAP REQ \r\n'
            assert(cursor < i, 'cap name too large')
            send('CAP', 'REQ', table.concat(request, ' ', cursor, i-1))
            size = n
            cursor = i
        end
    end
    if cursor <= #request then
        send('CAP', 'REQ', table.concat(request, ' ', cursor))
    end
end

local function wait_for_ack(task, request)
    local outstanding = Set(request)
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
end

function M.REQ(task, request)

    send_reqs(request)
    wait_for_ack(task, request)

    if irc_state:has_sasl() and irc_state.sasl_credentials then
        local credentials = irc_state.sasl_credentials
        irc_state.sasl_credentials = nil

        for _, credential in ipairs(credentials) do
            if irc_state:has_sasl_mech(credential.mechanism) 
            and sasl(task, credential)
            then
                break
            end
        end
    end
end

local ls_commands = Set{'CAP', N.RPL_WELCOME}

-- Used for the initial capability negotiation during registration
function M.LS(task)
    local more = true
    while more do
        local irc = task:wait_irc(ls_commands)
        if irc.command == 'CAP' and irc[2] == 'LS' then
            -- CAP * LS * :x y z    -- continuation
            -- CAP * LS :x y z      -- final
            local capsarg = irc[3]
            more = '*' == capsarg
            if more then
                capsarg = irc[4]
            end
            irc_state:add_caps(capsarg)
        elseif irc.command == N.RPL_WELCOME then
            return -- welcome means no cap negotiation
        end
    end

    local req = {}
    for cap, _ in pairs(irc_state.caps_available) do
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
