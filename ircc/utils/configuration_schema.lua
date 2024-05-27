local function table(fields)
    return {
        type = 'table',
        fields = fields
    }
end

local function required_table(fields)
    return {
        type = 'table',
	required = true,
        fields = fields,
    }
end

local function required_assocs(assocs)
    return {
        type = 'table',
	required = true,
        assocs = assocs,
    }
end

local function array(elements)
    return {
        type = 'table',
        elements = elements
    }
end

local command_schema = {
    type = 'table',
    fields = {
        command = {type = 'string', required = true},
        arguments = {type = 'table', elements = {type = 'string'}},
        multiline = {type = 'boolean', required = true},
    },
}

local prompt_schema = {
    type = 'table',
    fields = {
        prompt = {type = 'string', required = true}
    },
}

local file_schema = {
    type = 'table',
    fields = {
        file = {type = 'string', required = true}
    },
}

local password_schema = {
    -- not required - nil means no password
    oneOf = {
        {type = 'string'},
        command_schema,
        prompt_schema,
        file_schema,
     }
}

local required_password_schema = {
    required = true,
    oneOf = {
        {type = 'string'},
        command_schema,
        prompt_schema,
        file_schema,
     }
}

return table {
    identity = required_table {
        nick                = {type = 'string', pattern = '^[^\n\r\x00 ]+$', required = true},
        user                = {type = 'string', pattern = '^[^\n\r\x00 ]+$'},
        gecos               = {type = 'string', pattern = '^[^\n\r\x00]+$'},
    },
    server = required_table {
        host                = {type = 'string'},
        port                = {type = 'number'},
        fingerprint         = {type = 'string'},
        capabilities        = array {type = 'string', pattern = '^[^\n\r\x00 ]+$'},
        username             = {type = 'string', pattern = '^[^\n\r\x00:]*$'},
        password             = password_schema,
    },
    socks = table {
        host                = {type = 'string'},
        port                = {type = 'number'},
        username            = {type = 'string'},
        password            = password_schema,
    },
    tls = table {
        client_cert         = password_schema,
        client_key          = password_schema,
        client_password     = password_schema,
        verify_host         = {type = 'string'},
        sni_host            = {type = 'string'},
    },
    oper = table {
        automatic           = {type = 'boolean'},
        username            = {type = 'string', required = true, pattern = '^[^\n\r\x00 ]+$'},
        password            = required_password_schema,
    },
    challenge = table {
        automatic           = {type = 'boolean'},
	username            = {type = 'string', required = true},
        key                 = required_password_schema,
        password            = password_schema,
    },
    plugins = table {
        modules             = {type = 'table', elements = {type = 'string'}},
        directory           = {type = 'string'},
    },

    notifications = table {
        module              = {type = 'string', required = true},
    },

    mention = table {
	patterns            = array {type = 'string'},
    },

    sasl = table {
        automatic           = array {type = 'string'},
        credentials = required_assocs {
            mechanism       = {type = 'string', required = true},
            username        = {type = 'string'},
            password        = password_schema,
            key             = password_schema,
            authzid         = {type = 'string'},
        }
    },
}
