local Set = require 'pl.Set'

local send = require_ 'utils.send'

return function()

    irc_state = {
        phase = 'registration',
        caps_wanted = Set(configuration.irc_capabilities or {}),
        caps_enabled = Set{},
        caps_requested = Set{},
        batches = {},
        channels = {},
    }

    -- always request sasl cap when sasl is configured
    if configuration.irc_sasl_mechanism then
        irc_state.caps_wanted.sasl = true
        irc_state.want_sasl = true
    end

    if not Set.isempty(irc_state.caps_wanted) then
        send('CAP', 'LS', '302')
    end

    if configuration.irc_pass then
        send('PASS', {content=configuration.irc_pass, secret=true})
    end

    local nick  = configuration.irc_nick
    local user  = configuration.irc_user  or nick
    local gecos = configuration.irc_gecos or nick

    send('NICK', nick)
    send('USER', user, '*', '*', gecos)
end
