local cap_negotiation     <const> = require 'utils.cap_negotiation'
local challenge           <const> = require 'utils.challenge'
local configuration_tools <const> = require 'utils.configuration_tools'
local N                   <const> = require 'utils.numerics'
local send                <const> = require 'utils.send'
local Set                 <const> = require 'pl.Set'
local Task                <const> = require 'components.Task'

return function(task)
    irc_state.phase = 'registration'

    if configuration.server.capabilities then
        local wanted = irc_state.caps_wanted
        for _, cap in ipairs(configuration.server.capabilities) do
            local minus, name = cap:match '^(%-?)([^ ]+)$'
            if minus == '-' then
                wanted[name] = nil
            elseif name ~= nil then
                wanted[name] = true
            end
        end
    end

    if configuration.sasl and configuration.sasl.automatic then
        irc_state.sasl_credentials = {}
        for _, name in ipairs(configuration.sasl.automatic) do
            local credential = configuration_tools.get_credential(configuration.sasl.credentials, name)
            if not credential then
                error('Unknown credential in sasl.automatic: ' .. name)
            end
            table.insert(irc_state.sasl_credentials, credential)
        end
    end

    cap_negotiation.LS(task)

    do
        local success, password = pcall(configuration_tools.get_server_password, task, configuration.server)
        if success then
            if password then
                send('PASS', {content=password, secret=true})
            end
        else
            status('PASS', 'Password resolution failed: %s', password)
        end
    end

    local nick  = configuration.identity.nick
    local user  = configuration.identity.user  or nick
    local gecos = configuration.identity.gecos or nick

    send('NICK', nick)
    irc_state.nick = nick -- optimistic

    send('USER', user, '0', '*', gecos)

    -- "<client> :Welcome to the <networkname> Network, <nick>[!<user>@<host>]"
    local irc = task:wait_irc(Set{N.RPL_WELCOME})
    irc_state.nick = irc[1] -- first confirmation

    -- 005 is handled by the global IRC handler and is active outside of registration

    -- "<client> :End of /MOTD command."
    -- "<client> :MOTD File is missing"
    task:wait_irc(Set{N.RPL_ENDOFMOTD, N.ERR_NOMOTD})

    irc_state.phase = 'connected'
    status('irc', 'registered')

    -- Establish operator privs
    if configuration.challenge and configuration.challenge.automatic then
        Task('challenge', irc_state.tasks, challenge)
    elseif configuration.oper and configuration.oper.automatic then
        local password <const> = configuration_tools.resolve_password(task, configuration.oper.password)
        send('OPER', configuration.oper.username, {content=password, secret=true})
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
        send('MONITOR', '+', configuration.identity.nick)
    end
end
