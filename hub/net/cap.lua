-- Capability negotiation. LS and REQ run inside network tasks.

local irc_model <const> = require 'hub.net.irc'
local N         <const> = require 'hub.lib.numerics'
local sasl      <const> = require 'hub.net.sasl'

local M = {}

-- These tasks start once connected (registration, CAP NEW) and are
-- canceled when the connection ends
---@param t hub.Task
---@return hub.Irc
local function model(t)
    return HUB.state.nets[t.net].irc
end

-- Send as many CAP REQ commands as the request needs to fit in lines
local function send_reqs(t, request)
    local cursor = 1
    local size = 0
    for i, x in ipairs(request) do
        local n = 1 + #x -- 1 for : or space per req
        size = size + n
        if size > 502 then -- 512 - #'CAP REQ \r\n'
            assert(cursor < i, 'cap name too large')
            t:send('CAP', 'REQ', table.concat(request, ' ', cursor, i - 1))
            size = n
            cursor = i
        end
    end
    if cursor <= #request then
        t:send('CAP', 'REQ', table.concat(request, ' ', cursor))
    end
end

-- The CAP handler has recorded each ACK by the time the task sees it
local function wait_for_ack(t, request)
    local outstanding = {}
    for _, cap in ipairs(request) do
        outstanding[cap] = true
    end
    while next(outstanding) do
        local msg = t:wait_irc {'CAP'}
        local subcommand = msg[2]
        local caps = msg[3]

        -- CAP * <ACK|NAK> :x y z
        if subcommand == 'ACK' then
            for cap in caps:gmatch '[^ ]+' do
                outstanding[cap] = nil
            end
        elseif subcommand == 'NAK' then
            for cap in caps:gmatch '[^ ]+' do
                outstanding[cap] = nil
            end
            t:log('cap', "caps nak'd: %s", caps)
        end
    end
end

-- The wanted capabilities among `offered` (names) that aren't enabled,
-- sorted, leaving out those whose requirements wouldn't be met
local function wanted(irc, offered)
    local set = {}
    for _, cap in ipairs(offered) do
        if irc.caps_wanted[cap] and not irc.caps_enabled[cap] then
            set[cap] = true
        end
    end
    local req = {}
    for cap in pairs(set) do
        if irc_model.cap_satisfied(irc, cap, set) then
            table.insert(req, cap)
        end
    end
    table.sort(req)
    return req
end

--- Turn off enabled capabilities whose requirements are gone, as after a
--- NAK or CAP DEL.
---@param t hub.Task
function M.drop_unsatisfied(t)
    local irc = model(t)
    local req = {}
    for cap in pairs(irc_model.caps_required) do
        if irc.caps_enabled[cap] and not irc_model.cap_satisfied(irc, cap) then
            table.insert(req, '-' .. cap)
        end
    end
    table.sort(req)
    if next(req) then
        send_reqs(t, req)
        wait_for_ack(t, req)
    end
end

--- Request capabilities, then authenticate if SASL was just enabled and
--- credentials are waiting. Credentials are used once, by the first REQ.
function M.REQ(t, request)
    send_reqs(t, request)
    wait_for_ack(t, request)
    M.drop_unsatisfied(t)

    local irc = model(t)
    local credentials = irc.sasl_credentials
    if irc_model.has_sasl(irc) and credentials then
        irc.sasl_credentials = nil
        for _, credential in ipairs(credentials) do
            if irc_model.has_sasl_mech(irc, credential.mechanism)
            and sasl.authenticate(t, credential)
            then
                break
            end
        end
    end
end

--- The initial negotiation during registration, after CAP LS was sent.
--- Ends negotiation with CAP END.
---@param t hub.Task
---@return hub.Message|nil # RPL_WELCOME if the server registered without CAP
function M.LS(t)
    local irc = model(t)
    local more = true
    while more do
        local msg = t:wait_irc {'CAP', N.RPL_WELCOME, N.ERR_UNKNOWNCOMMAND}
        if msg.command == 'CAP' and msg[2] == 'LS' then
            -- CAP * LS * :x y z    -- continuation
            -- CAP * LS :x y z      -- final
            local capsarg = msg[3]
            more = '*' == capsarg
            if more then
                capsarg = msg[4]
            end
            irc_model.add_caps(irc, capsarg)
        elseif msg.command == N.RPL_WELCOME then
            return msg -- the server doesn't negotiate capabilities
        elseif msg.command == N.ERR_UNKNOWNCOMMAND and msg[2] == 'CAP' then
            return
        end
    end

    local offered = {}
    for cap in pairs(irc.caps_available) do
        table.insert(offered, cap)
    end
    local req = wanted(irc, offered)

    if next(req) then
        M.REQ(t, req)
    end

    t:send('CAP', 'END')
end

--- Handle CAP subcommands as they arrive. An ACK is recorded whoever
--- asked, so a CAP REQ sent by hand takes effect too.
---@param net string
---@param irc hub.Irc
---@param msg hub.Message
---@param spawn fun(name: string, fn: fun(t: hub.Task, ...), ...) starts a task on the network
function M.on_cap(net, irc, msg, spawn)
    local sub = msg[2]
    if sub == 'ACK' then
        irc_model.ack_caps(irc, msg[3])
    elseif sub == 'DEL' then
        irc_model.del_caps(irc, msg[3])
        if HUB.state.nets[net].phase == 'connected' then
            spawn('cap negotiation', M.drop_unsatisfied)
        end
    elseif sub == 'NEW' then
        local offered = {}
        for cap in pairs(irc_model.add_caps(irc, msg[3])) do
            table.insert(offered, cap)
        end
        local req = wanted(irc, offered)
        if next(req) and HUB.state.nets[net].phase == 'connected' then
            spawn('cap negotiation', M.REQ, req)
        end
    end
end

return M
