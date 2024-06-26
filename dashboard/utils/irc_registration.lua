local send = require_ 'utils.send'
local cap_negotiation = require 'utils.cap_negotiation'
local Task = require 'components.Task'
local configuration_tools = require 'utils.configuration_tools'

return function(task)
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

    send('CAP', 'LS', '302')
    Task(irc_state.tasks, cap_negotiation.LS)

    if configuration.server.password then
        local pass = configuration_tools.resolve_password(task, configuration.server.password)
        if configuration.server.username then
            pass = configuration.server.username .. ':' .. pass
        end
        send('PASS', {content=pass, secret=true})
    end

    local nick  = configuration.identity.nick
    local user  = configuration.identity.user  or nick
    local gecos = configuration.identity.gecos or nick

    send('NICK', nick)
    irc_state.nick = nick -- optimistic

    send('USER', user, '0', '*', gecos)
end
