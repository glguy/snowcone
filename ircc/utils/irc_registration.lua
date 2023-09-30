local send = require_ 'utils.send'
local cap_negotiation = require 'utils.cap_negotiation'
local Task = require 'components.Task'
local N = require 'utils.numerics'
local Set = require 'pl.Set'
local challenge   = require_ 'utils.challenge'

return function(task)
    if configuration.capabilities then
        local wanted = irc_state.caps_wanted
        for _, cap in ipairs(configuration.capabilities) do
            local minus, name = cap:match '^(%-?)([^ ]+)$'
            if minus == '-' then
                wanted[name] = nil
            elseif name ~= nil then
                wanted[name] = true
            end
        end
    end

    local credentials = configuration.sasl_credentials
    irc_state.sasl_credentials = credentials and credentials.default

    send('CAP', 'LS', '302')
    Task('cap negotiation', irc_state.tasks, cap_negotiation.LS)

    if configuration.pass then
        local pass = configuration.pass
        if configuration.passuser then
            pass = configuration.passuser .. ':' .. pass
        end
        send('PASS', {content=pass, secret=true})
    end

    local nick  = configuration.nick
    local user  = configuration.user  or nick
    local gecos = configuration.gecos or nick

    send('NICK', nick)
    irc_state.nick = nick -- optimistic

    send('USER', user, '*', '*', gecos)

    -- "<client> :Welcome to the <networkname> Network, <nick>[!<user>@<host>]"
    local irc = task:wait_irc(Set{N.RPL_WELCOME})
    irc_state.nick = irc[1] -- first confirmation

    -- 005 is handled by the global IRC handler and is active outside of registration

    -- "<client> :End of /MOTD command."
    -- "<client> :MOTD File is missing"
    task:wait_irc(Set{N.RPL_ENDOFMOTD, N.ERR_NOMOTD})

    irc_state.phase = 'connected'
    status('irc', 'connected')

    -- Establish operator privs
    if configuration.oper_username and configuration.challenge_key then
        Task('challenge', irc_state.tasks, challenge)
    elseif configuration.oper_username and configuration.oper_password then
        send('OPER', configuration.oper_username,
            {content=configuration.oper_password, secret=true})
    else
        -- determine if we're already oper
        send('MODE', irc_state.nick)
    end

    -- Populate talk buffer chat history
    if irc_state:has_chathistory() then
        local supported_amount = irc_state.max_chat_history
        for target, buffer in pairs(buffers) do
            local amount = buffer.messages.max

            if supported_amount and supported_amount < amount then
                amount = supported_amount
            end

            local ts
            local lastirc = buffer.messages:lookup(true)
            if lastirc and lastirc.tags.time then
                ts = 'timestamp=' .. lastirc.tags.time
            else
                ts = '*'
            end

            send('CHATHISTORY', 'LATEST', target, ts, amount)
        end
    end

    -- reinstall monitors for the active private message buffers
    if irc_state:has_monitor() then
        local n, nicks = 0, {}
        for target, _ in pairs(buffers) do
            if not irc_state:is_channel_name(target) then
                table.insert(nicks, target)
                n = 1 + #target
                if n > 400 then
                    send('MONITOR', '+', table.concat(nicks, ','))
                    n, nicks = 0, {}
                end
            end
        end
        if n > 0 then
            send('MONITOR', '+', table.concat(nicks, ','))
        end
    end

    -- start waiting for our nickname
    if irc_state.recover_nick and irc_state:has_monitor() then
        send('MONITOR', '+', configuration.nick)
    end
end
