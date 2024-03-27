local send = require_ 'utils.send'
local cap_negotiation = require 'utils.cap_negotiation'
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

    if configuration.sasl_automatic then
        irc_state.sasl_credentials = {}
        for _, name in ipairs(configuration.sasl_automatic) do
            local credential = configuration.sasl_credentials[name]
            if not credential then
                error('Unknown credential in sasl_automatic: ' .. name)
            end
            table.insert(irc_state.sasl_credentials, credential)
        end
    elseif configuration.sasl_credentials and configuration.sasl_credentials.default then
        irc_state.sasl_credentials = {configuration.sasl_credentials.default}
    end

    cap_negotiation.LS(task)

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

    send('USER', user, '0', '*', gecos)

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
        challenge(task)
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
