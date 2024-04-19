return {
    type = 'table',
    fields = {
        host                = {type = 'string', required = true},
        port                = {type = 'number'},
        socks_host          = {type = 'string'},
        socks_port          = {type = 'number'},
        socks_username      = {type = 'string'},
        socks_password      = {type = 'string'},
        bind_host           = {type = 'string'},
        bind_port           = {type = 'number'},
        tls                 = {type = 'boolean'},
        tls_client_cert     = {type = 'string'},
        tls_client_key      = {type = 'string'},
        tls_client_password = {type = 'string'},
        tls_verify_host     = {type = 'string'},
        tls_sni_host        = {type = 'string'},
        fingerprint         = {type = 'string'},
        nick                = {type = 'string', pattern = '^[^\n\r\x00 ]+$', required = true},
        user                = {type = 'string', pattern = '^[^\n\r\x00 ]+$'},
        gecos               = {type = 'string', pattern = '^[^\n\r\x00]+$'},
        passuser            = {type = 'string', pattern = '^[^\n\r\x00:]*$'},
        pass                = {type = 'string', pattern = '^[^\n\r\x00]*$'},
        oper_username       = {type = 'string', pattern = '^[^\n\r\x00 ]+$'},
        oper_password       = {type = 'string', pattern = '^[^\n\r\x00]*$'},
        challenge_key       = {type = 'string'},
        challenge_password  = {type = 'string'},
        plugin_dir          = {type = 'string'},
        plugins             = {type = 'table', elements = {type = 'string', required = true}},
        notification_module = {type = 'string'},
        capabilities        = {
            type = 'table',
            elements = {type = 'string', pattern = '^[^\n\r\x00 ]+$', required = true}
        },
        mention_patterns    = {
            type = 'table',
            elements = {type = 'string', required = true}
        },
        sasl_automatic      = {
            type = 'table',
            elements = {type = 'string', required = true}
        },
        sasl_credentials    = {
            type = 'table',
            assocs = {
                type = 'table',
                fields = {
                    mechanism   = {type = 'string', required = true},
                    username    = {type = 'string'},
                    password    = {type = 'string'},
                    key         = {type = 'string'},
                    authzid     = {type = 'string'},
        }}},
    }
}
