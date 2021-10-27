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
        local key_txt = assert(file.read(configuration.irc_sasl_ecdsa_key))
        return irc_authentication.ecdsa_challenge(key_txt, configuration.irc_sasl_ecdsa_password, arg)
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

function M.ECDH_X25519_CHALLENGE_1()
    if configuration.irc_sasl_authzid then
        return 'ECDH_X25519_CHALLENGE_2',
            configuration.irc_sasl_username .. '\0' ..
            configuration.irc_sasl_authzid
    else
        return 'ECDH_X25519_CHALLENGE_2',
            configuration.irc_sasl_username
    end
end

function M.ECDH_X25519_CHALLENGE_2(server_response)
    local success, message = pcall(function()
        local client_secpem = assert(file.read(configuration.irc_sasl_ecdh_key))
        return irc_authentication.ecdh_challenge(client_secpem, configuration.irc_sasl_ecdh_password, server_response)
    end)

    if success then
        return 'done', message
    else
        return 'aborted'
    end
end

return M
