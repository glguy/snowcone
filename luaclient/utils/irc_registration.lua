local Irc = require_ 'components.Irc'

local send = require_ 'utils.send'

return function()

    irc_state = Irc()

    if configuration.irc_capabilities then
        local wanted = {}
        for _, cap in ipairs(configuration.irc_capabilities) do
            wanted[cap] = true
        end
        irc_state.caps_wanted = wanted
    end

    -- always request sasl cap when sasl is configured
    local credentials = configuration.sasl_credentials
    local default_credentials = credentials and credentials.default
    if default_credentials then
        irc_state.caps_wanted.sasl = true
        irc_state.sasl_credentials = default_credentials
    end

    send('CAP', 'LS', '302')

    if configuration.irc_pass then
        send('PASS', {content=configuration.irc_pass, secret=true})
    end

    local nick  = configuration.irc_nick
    local user  = configuration.irc_user  or nick
    local gecos = configuration.irc_gecos or nick

    send('NICK', nick)
    send('USER', user, '*', '*', gecos)
end
