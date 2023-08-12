local Set = require 'pl.Set'

local send = require_ 'utils.send'

return function()

    irc_state = {
        phase = 'registration',
        caps_enabled = Set{},
        caps_requested = Set{}
    }

    local caps_wanted = Set{}

    -- always request sasl cap when sasl is configured
    if configuration.irc_sasl_mechanism then
        caps_wanted.sasl = true
        irc_state.want_sasl = true
    end

    -- add in all the manually requested caps
    if configuration.irc_capabilities then
        for cap in configuration.irc_capabilities:gmatch '[%w%-./]+' do
            caps_wanted[cap] = true
        end
    end

    if not Set.isempty(caps_wanted) then
        send('CAP', 'LS', '302')
        irc_state.caps_wanted = caps_wanted
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
