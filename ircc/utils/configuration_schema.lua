local command_schema = {
    type = 'table',
    fields = {
        command = {type = 'string', required = true},
        arguments = {type = 'table', elements = {type = 'string'}},
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

return {
    type = 'table',
    fields = {
        nick                = {type = 'string', pattern = '^[^\n\r\x00 ]+$', required = true},
        user                = {type = 'string', pattern = '^[^\n\r\x00 ]+$'},
        gecos               = {type = 'string', pattern = '^[^\n\r\x00]+$'},

        host                = {type = 'string'},
        port                = {type = 'number'},

        socks_host          = {type = 'string'},
        socks_port          = {type = 'number'},
        socks_username      = {type = 'string'},
        socks_password      = password_schema,

        tls                 = {type = 'boolean'},
        tls_client_cert     = password_schema,
        tls_client_key      = password_schema,
        tls_client_password = password_schema,
        tls_verify_host     = {type = 'string'},
        tls_sni_host        = {type = 'string'},

        fingerprint         = {type = 'string'},

        passuser            = {type = 'string', pattern = '^[^\n\r\x00:]*$'},
        pass                = password_schema,

        oper_automatic      = {type = 'string'},
        oper_username       = {type = 'string', pattern = '^[^\n\r\x00 ]+$'},
        oper_password       = password_schema,
        challenge_key       = password_schema,
        challenge_password  = password_schema,

        plugin_dir          = {type = 'string'},
        plugins             = {type = 'table', elements = {type = 'string'}},

        notification_module = {type = 'string'},

        capabilities = {
            type = 'table',
            elements = {type = 'string', pattern = '^[^\n\r\x00 ]+$'}
        },
        mention_patterns = {
            type = 'table',
            elements = {type = 'string'}
        },

        sasl_automatic = {
            type = 'table',
            elements = {type = 'string'}
        },
        sasl_credentials    = {
            type = 'table',
            assocs = {
                type = 'table',
                fields = {
                    mechanism   = {type = 'string', required = true},
                    username    = {type = 'string'},
                    password    = password_schema,
                    key         = password_schema,
                    authzid     = {type = 'string'},
        }}},
    }
}
