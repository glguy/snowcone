-- Configuration schema. Every connection setting is per network, under
-- [[networks]]. Checks for spaces and line breaks are schema constraints.

local M = {}

local function table_(fields)
    return {type = 'table', fields = fields}
end

local function required_table(fields)
    return {type = 'table', required = true, fields = fields}
end

local function array(elements)
    return {type = 'table', elements = elements}
end

-- No spaces, line breaks or NUL: a single IRC parameter
local word <const> = '^[^\n\r\x00 ]+$'
-- No line breaks or NUL: may be the last IRC parameter
local line <const> = '^[^\n\r\x00]*$'

-- A TCP port number. 0 is excluded: it is not a usable port.
local required_port_schema <const> = {
    type = 'number', integer = true, minimum = 1, maximum = 65535, required = true,
}

local command_schema <const> = table_ {
    command = {type = 'string', required = true},
    arguments = array {type = 'string'},
    multiline = {type = 'boolean'},
    use_tty = {type = 'boolean'},
}

local prompt_schema <const> = table_ {
    prompt = {type = 'string', required = true},
}

local file_schema <const> = table_ {
    file = {type = 'string', required = true},
}

local function password(string_schema, required)
    return {
        required = required,
        oneOf = {string_schema, command_schema, prompt_schema, file_schema},
    }
end

-- Secrets that may hold anything, such as PEM text
local password_schema <const> = password {type = 'string'}
local required_password_schema <const> = password({type = 'string'}, true)
-- Secrets sent as part of an IRC line
local line_password_schema <const> = password {type = 'string', pattern = line}
local required_line_password_schema <const> = password({type = 'string', pattern = line}, true)

local identity_fields <const> = {
    nick  = {type = 'string', pattern = word, required = true},
    user  = {type = 'string', pattern = word},
    gecos = {type = 'string', pattern = '^[^\n\r\x00]+$'},
}

-- host and port for TCP, or path for a local (unix-domain) socket;
-- config.lua checks that exactly one is given
local server_fields <const> = {
    host         = {type = 'string'},
    port         = {type = 'number', integer = true, minimum = 1, maximum = 65535},
    path         = {type = 'string'},
    fingerprint  = {type = 'string'},
    capabilities = array {type = 'string', pattern = word},
    username     = {type = 'string', pattern = '^[^\n\r\x00:]*$'},
    password     = line_password_schema,
}

local proxy_host_schema <const> = {type = 'string', pattern = '.', expected = 'a host name', required = true}

-- RFC 1929: a username and password of 1 to 255 bytes; the native layer
-- refuses longer ones, and a resolved secret is checked when connecting
local non_empty <const> = {type = 'string', pattern = '.', expected = 'a non-empty string'}

local socks_layer <const> = table_ {
    type     = {type = 'string', pattern = '^socks$', required = true},
    host     = proxy_host_schema,
    port     = required_port_schema,
    username = non_empty,
    password = password(non_empty),
}

-- RFC 7617: the user-id ends at the first colon, so it can't contain one
local http_layer <const> = table_ {
    type     = {type = 'string', pattern = '^http$', required = true},
    host     = proxy_host_schema,
    port     = required_port_schema,
    username = {type = 'string', pattern = '^[^:]*$', expected = 'no colon'},
    password = password_schema,
}

local layers_schema <const> = array {
    oneOf = {
        socks_layer,
        http_layer,
        table_ {
            type            = {type = 'string', pattern = '^tls$', required = true},
            client_cert     = password_schema,
            client_key      = password_schema,
            client_password = password_schema,
            use_store       = {type = 'boolean'},
            verify_host     = {type = 'string'},
            sni_host        = {type = 'string'},
            alpn            = array {type = 'string'},
        },
    },
}

local oper_schema <const> = table_ {
    automatic = {type = 'boolean'},
    username  = {type = 'string', required = true, pattern = word},
    password  = required_line_password_schema,
}

local challenge_schema <const> = table_ {
    automatic = {type = 'boolean'},
    username  = {type = 'string', required = true, pattern = word},
    key       = required_password_schema,
    password  = password_schema,
    use_store = {type = 'boolean'},
}

local sasl_schema <const> = table_ {
    automatic = array {type = 'string'},
    credentials = array (table_ {
        name      = {type = 'string'},
        mechanism = {type = 'string', required = true},
        username  = {type = 'string'},
        password  = password_schema,
        key       = password_schema,
        use_store = {type = 'boolean'},
        authzid   = {type = 'string'},
    }),
}

local mention_schema <const> = table_ {
    patterns = array {type = 'string'},
}

local delay_schema <const> = {type = 'number', minimum = 0}

-- Lines that may go at once, and seconds to earn back one; config.lua
-- checks that interval is above 0
local rate_limit_schema <const> = table_ {
    burst    = {type = 'number', integer = true, minimum = 1, required = true},
    interval = {type = 'number', minimum = 0, required = true},
}

--- The features a network may enable; config.lua checks names against it.
M.features = {'snotice', 'oper', 'topology', 'chat'}

--- One entry of [[networks]].
M.network = table_ {
    id           = {type = 'string', required = true, pattern = '^[%w_.%-]+$'},
    features     = array {type = 'string'},
    autoconnect  = {type = 'boolean'},
    reconnect    = table_ {min_delay = delay_schema, max_delay = delay_schema},
    rate_limit   = rate_limit_schema,
    reclaim_nick = {type = 'boolean'},
    snomask      = {type = 'string', pattern = word},
    quit_message = {type = 'string', pattern = line},
    servers_file = {type = 'string'},
    server       = required_table(server_fields),
    layers       = layers_schema,
    identity     = required_table(identity_fields),
    sasl         = sasl_schema,
    oper         = oper_schema,
    challenge    = challenge_schema,
    mention      = mention_schema,
    watches      = array (table_ {
        pattern = {type = 'string', required = true},
        colour  = {type = 'string', pattern = '^%l+$'},
        beep    = {type = 'boolean'},
        flash   = {type = 'boolean'},
        active  = {type = 'boolean'},
    }),
}

--- The whole file.
M.file = table_ {
    ui = table_ {
        profile = {type = 'string', pattern = '^%l+$'},
    },
    networks = array {type = 'table'}, -- each checked against M.network
    plugins = table_ {
        modules   = array {type = 'string'},
        directory = {type = 'string'},
        custom    = {type = 'table'},
    },
    notifications = table_ {
        module = {type = 'string', required = true, pattern = '^%w+$',
                  expected = 'a backend name: bell, mac or iterm2'},
    },
    mention = mention_schema,
}

return M
