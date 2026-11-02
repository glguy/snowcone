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

-- A table of any keys whose values all match one schema
local function assocs(values)
    return {type = 'table', assocs = values}
end

-- No spaces, line breaks or NUL: a single IRC parameter
local word <const> = '^[^\n\r\x00 ]+$'
-- A word not starting with ':': a parameter that may come before others
local middle <const> = '^[^\n\r\x00 :][^\n\r\x00 ]*$'
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
-- Secrets sent as part of an IRC line
local line_password_schema <const> = password {type = 'string', pattern = line}
local required_line_password_schema <const> = password({type = 'string', pattern = line}, true)

-- A private key: a secret holding its text, or the name of a key in an
-- OpenSSL store, such as a pkcs11: URI
local function private_key(required)
    return {
        required = required,
        oneOf = {
            {type = 'string'}, command_schema, prompt_schema, file_schema,
            table_ {store = {type = 'string', pattern = '.', expected = 'a store name', required = true}},
        },
    }
end
local key_schema <const> = private_key()
local required_key_schema <const> = private_key(true)

local identity_fields <const> = {
    nick     = {type = 'string', pattern = word, required = true},
    user     = {type = 'string', pattern = middle},
    realname = {type = 'string', pattern = '^[^\n\r\x00]+$'},
    bot      = {type = 'boolean'},
}

-- host and port for TCP, or path for a local (unix-domain) socket;
-- config.lua checks that exactly one is given
local server_fields <const> = {
    host = {type = 'string'},
    port = {type = 'number', integer = true, minimum = 1, maximum = 65535},
    path = {type = 'string'},
}

-- What is sent before registering: PASS and the capabilities to request
local registration_schema <const> = table_ {
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

-- IRC over a WebSocket, on top of every layer. Sent in the HTTP request
-- that opens it, so no spaces or control characters
local websocket_schema <const> = table_ {
    host   = {type = 'string', pattern = '^[^%c ]+$', expected = 'no spaces or control characters'},
    path   = {type = 'string', pattern = '^/[^%c ]*$',
              expected = "a path starting with '/', without spaces or control characters"},
    origin = {type = 'string', pattern = '^[^%c ]+$', expected = 'no spaces or control characters'},
    subprotocols = array {oneOf = {
        {type = 'string', pattern = '^binary%.ircv3%.net$'},
        {type = 'string', pattern = '^text%.ircv3%.net$'},
    }},
}

local layers_schema <const> = array {
    oneOf = {
        socks_layer,
        http_layer,
        table_ {
            type            = {type = 'string', pattern = '^tls$', required = true},
            client_cert     = password_schema,
            client_key      = key_schema,
            client_password = password_schema,
            verify_host     = {type = 'string'},
            sni_host        = {type = 'string'},
            alpn            = array {type = 'string'},
            pin             = {type = 'string', pattern = '^' .. string.rep('%x', 64) .. '$',
                               expected = 'a SHA-256 in 64 hex digits'},
        },
    },
}

-- Operator logins, named like SASL credentials: OPER with a password,
-- or CHALLENGE with an RSA key
local oper_schema <const> = table_ {
    automatic = array {type = 'string'},
    credentials = array {oneOf = {
        table_ {
            name      = {type = 'string'},
            mechanism = {type = 'string', pattern = '^password$', required = true},
            username  = {type = 'string', required = true, pattern = middle},
            password  = required_line_password_schema,
        },
        table_ {
            name      = {type = 'string'},
            mechanism = {type = 'string', pattern = '^challenge$', required = true},
            username  = {type = 'string', required = true, pattern = middle},
            key       = required_key_schema,
            password  = password_schema,
        },
    }},
}

local sasl_schema <const> = table_ {
    automatic = array {type = 'string'},
    credentials = array (table_ {
        name      = {type = 'string'},
        mechanism = {type = 'string', required = true},
        username  = {type = 'string'},
        password  = password_schema,
        key       = key_schema,
        authzid   = {type = 'string'},
    }),
}

local mention_schema <const> = table_ {
    patterns = array {type = 'string'},
}

-- No shorter than this, so a refused connection can't spin
local delay_schema <const> = {type = 'number', minimum = 0.1}

-- Lines that may go at once, and seconds to earn back one; config.lua
-- checks that interval is above 0
local rate_limit_schema <const> = table_ {
    burst    = {type = 'number', integer = true, minimum = 1, required = true},
    interval = {type = 'number', minimum = 0, required = true},
}

--- The features a network may enable; config.lua checks names against it.
M.features = {'snotice', 'oper', 'topology', 'chat'}

--- The features each feature needs on the same network; config.lua
--- refuses a network that enables one without them. Only combinations
--- that work are allowed: oper stages K-Lines that only snotice's views
--- show and send.
M.feature_requires = {
    oper = {'snotice'},
}

--- The server software a network may run; config.lua checks `ircd`
--- against it.
M.ircds = {'solanum', 'oftc-hybrid'}

--- One entry of [[networks]].
M.network = table_ {
    id           = {type = 'string', required = true, pattern = '^[%w_.%-]+$'},
    ircd         = {type = 'string'},
    features     = array {type = 'string'},
    autoconnect  = {type = 'boolean'},
    reconnect    = table_ {min_delay = delay_schema, max_delay = delay_schema},
    rate_limit   = rate_limit_schema,
    reclaim_nick = {type = 'boolean'},
    channels     = array {type = 'string', pattern = '^[^\n\r\x00 ,]+$'},
    snomask      = {type = 'string', pattern = middle},
    quit_message = {type = 'string', pattern = line},
    servers_file = {type = 'string'},
    server       = required_table(server_fields),
    layers       = layers_schema,
    websocket    = websocket_schema,
    identity     = required_table(identity_fields),
    registration = registration_schema,
    sasl         = sasl_schema,
    oper         = oper_schema,
    mention      = mention_schema,
    watches      = array (table_ {
        pattern = {type = 'string', required = true},
        color  = {type = 'string', pattern = '^%l+$'},
        beep    = {type = 'boolean'},
        flash   = {type = 'boolean'},
        active  = {type = 'boolean'},
    }),
}

--- A network's servers file (servers_file).
M.servers_file = table_ {
    primary_hub   = {type = 'string'},
    flags         = array {type = 'string'},
    servers       = assocs (table_ {
        alias  = {type = 'string'},
        region = {type = 'string'},
        ipv4   = {type = 'string'},
        ipv6   = {type = 'string'},
        expect = array {type = 'string'},
    }),
    regions       = assocs (table_ {
        hostname = {type = 'string'},
        color    = {type = 'string', pattern = '^%l+$'},
    }),
    kline_reasons = array (table_ {
        name   = {type = 'string', pattern = line, required = true},
        reason = {type = 'string', pattern = line, required = true},
    }),
    kline_tags    = array {type = 'string', pattern = word},
    net_tracks    = assocs (array {type = 'string'}),
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
        backend = {type = 'string', required = true, pattern = '^%w+$',
                   expected = 'a backend name: bell, mac or iterm2'},
    },
    mention = mention_schema,
}

return M
