local Irc = require_ 'components.Irc'

local send = require_ 'utils.send'

return function()

    irc_state = Irc()

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

    if configuration.pass then
        send('PASS', {content=configuration.pass, secret=true})
    end

    local nick  = configuration.nick
    local user  = configuration.user  or nick
    local gecos = configuration.gecos or nick

    send('NICK', nick)
    send('USER', user, '*', '*', gecos)
end
