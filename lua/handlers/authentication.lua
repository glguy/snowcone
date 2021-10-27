local M = {}

local function protect(f, clean)
    local success, state, message = pcall(f)
    if success then
        return state, message
    else
        if clean then clean() end
        return 'aborted'
    end
end

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
    return protect(function()
        local key_txt = assert(file.read(configuration.irc_sasl_ecdsa_key))
        local message = irc_authentication.ecdsa_challenge(key_txt, configuration.irc_sasl_ecdsa_password, arg)
        return 'done', message
    end)
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
    return protect(function()
        local client_secpem = assert(file.read(configuration.irc_sasl_ecdh_key))
        local message = irc_authentication.ecdh_challenge(client_secpem, configuration.irc_sasl_ecdh_password, server_response)
        return 'done', message
    end)
end

function M.SCRAM_1()
    return protect(function()
        return 'SCRAM_2', irc_state.scram:client_first()
    end,
    function() irc_state.scram = nil end)
end

function M.SCRAM_2(server_first)
    return protect(function()
        return 'SCRAM_3', irc_state.scram:client_final(server_first)
    end,
    function() irc_state.scram = nil end)
end

function M.SCRAM_3(server_final)
    return protect(function()
        local response = irc_state.scram:verify(server_final)
        irc_state.scram = nil
        return 'done', response
    end,
    function() irc_state.scram = nil end)
end

return M
