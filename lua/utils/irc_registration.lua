local send = require_ 'utils.send'
local Set = require 'pl.Set'

return function()

    local caps_wanted = Set{}
    irc_state.caps_enabled = Set{}

    -- always request sasl cap when sasl is configured
    if configuration.irc_sasl_mechanism then
        caps_wanted.sasl = true
        irc_state.want_sasl = true
    end

    -- add in all the manually requested caps
    if configuration.irc_capabilities then
        for cap in configuration.irc_capabilities:gmatch '%S+' do
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

    local nick = configuration.irc_nick
    local user = configuration.irc_user or configuration.irc_nick
    local gecos = configuration.irc_gecos or configuration.irc_nick

    irc_state.nick = nick
    irc_state.registration = true
    send('NICK', nick)
    send('USER', user, '*', '*', gecos)
end
