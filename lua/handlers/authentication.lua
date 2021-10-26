local M = {}

function M.ECDSA_NIST256P_CHALLENGE_1()
    if configuration.irc_sasl_authzid then
        return 'ECDSA_NIST256P_CHALLENGE_2',
            configuration.irc_sasl_username .. '\0' ..
            configuration.irc_sasl_authzid
    else
        return 'ECDSA_NIST256P_CHALLENGE_2',
            configuration.irc_sasl_username
    end
end

function M.ECDSA_NIST256P_CHALLENGE_2(arg)
    local success, message = pcall(function()
        local key_der = assert(file.read(configuration.irc_sasl_ecdsa_key))
        return irc_authentication.ecdsa_challenge(key_der, arg)
    end)

    if success then
        return 'done', message
    else
        return 'aborted'
    end
end

function M.EXTERNAL()
    return 'done',
        configuration.irc_sasl_authzid or ''
end

function M.PLAIN()
    return 'done',
        (configuration.irc_sasl_authzid or '') .. '\0' ..
        configuration.irc_sasl_username        .. '\0' ..
        configuration.irc_sasl_password
end

return M
