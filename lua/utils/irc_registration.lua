local sasl = require_ 'sasl'
local send = require_ 'utils.send'

return function()

    local caps = {}

    local postreg
    local mech = configuration.irc_sasl_mechanism
    if mech then
        local success
        success, postreg, irc_state.sasl = pcall(sasl.start,
            configuration.irc_sasl_mechanism,
            configuration.irc_sasl_username,
            configuration.irc_sasl_password,
            configuration.irc_sasl_key,
            configuration.irc_sasl_authzid
        )
        if success then
            table.insert(caps, 'sasl')
        else
            status('error', '%s', postreg)
            postreg = nil
        end
    end

    if configuration.irc_capabilities then
        table.insert(caps, configuration.irc_capabilities)
    end

    if next(caps) then
        send('CAP', 'LS', '302')
        send('CAP', 'REQ', table.concat(caps, ' '))
        if not postreg then
            postreg = {'CAP', 'END'}
        end
    end

    if configuration.irc_pass then
        send('PASS', {content=configuration.irc_pass, secret=true})
    end

    local user = configuration.irc_user or configuration.irc_nick
    local gecos = configuration.irc_gecos or configuration.irc_nick

    irc_state.registration = true
    send('NICK', configuration.irc_nick)
    send('USER', user, '*', '*', gecos)

    if postreg then
        send(table.unpack(postreg))
    end
end
