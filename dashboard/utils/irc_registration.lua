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

    -- always request sasl cap when sasl is configured
    local credentials = configuration.sasl_credentials
    local default_credentials = credentials and credentials.default
    if default_credentials then
        irc_state.caps_wanted.sasl = true
        irc_state.sasl_credentials = default_credentials
    end

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
