-- Tests for ircc/utils/schema.lua and the connection layer / port rules in
-- ircc/utils/configuration_schema.lua.
--
-- Run from the repository root:  lua tests/test-schema.lua

local here = (arg and arg[0] or ''):match('^(.*)/[^/]*$') or '.'
package.path = here .. '/../ircc/?.lua;' .. here .. '/../ircc/?/init.lua;' .. package.path

-- The client provides Penlight; only tablex.copy is needed here.
package.preload['pl.tablex'] = function()
    return {
        copy = function(t)
            local r = {}
            for k, v in pairs(t) do r[k] = v end
            return r
        end,
    }
end

local unexpected
function status(_, fmt, ...) unexpected = string.format(fmt, ...) end

local schema = require 'utils.schema'
local configuration_schema = require 'utils.configuration_schema'

local function config(server, layers)
    return {
        identity = {nick = 'nick'},
        server = server or {host = 'irc.example.org', port = 6697},
        layers = layers,
    }
end

local function accepts(what, cfg)
    unexpected = nil
    local ok, err = pcall(schema.check, configuration_schema, cfg)
    if not ok then error('expected ' .. what .. ' to be accepted: ' .. tostring(err), 2) end
    if unexpected then error('unexpected-field warning for ' .. what .. ': ' .. unexpected, 2) end
end

local function rejects(what, cfg)
    if pcall(schema.check, configuration_schema, cfg) then
        error('expected ' .. what .. ' to be rejected', 2)
    end
end

-- valid layer configurations
accepts('no layers', config())
accepts('tls layer', config(nil, {{type = 'tls', verify_host = 'h', sni_host = 's'}}))
accepts('tls alpn', config(nil, {{type = 'tls', alpn = {'irc', 'http/1.1'}}}))
rejects('tls alpn string', config(nil, {{type = 'tls', alpn = 'irc'}}))
rejects('tls alpn number', config(nil, {{type = 'tls', alpn = {7}}}))
accepts('socks layer', config(nil, {{type = 'socks', host = 'localhost', port = 9050}}))
accepts('socks with credentials',
    config(nil, {{type = 'socks', host = 'h', port = 1080, username = 'u', password = 'p'}}))
accepts('http with credentials',
    config(nil, {{type = 'http', host = 'h', port = 8080, username = 'u', password = {file = 'pw'}}}))
accepts('stacked layers',
    config(nil, {{type = 'socks', host = 'h', port = 1080}, {type = 'tls'}}))
accepts('integral float port', config(nil, {{type = 'socks', host = 'h', port = 1080.0}}))

-- every layer needs a known type
rejects('layer without type', config(nil, {{host = 'h', port = 1}}))
rejects('empty layer', config(nil, {{}}))
rejects('misspelled type', config(nil, {{type = 'tsl'}}))
rejects('non-string type', config(nil, {{type = 7}}))

-- proxies need a host and a port
rejects('socks without host', config(nil, {{type = 'socks', port = 1080}}))
rejects('socks without port', config(nil, {{type = 'socks', host = 'h'}}))
rejects('http without host', config(nil, {{type = 'http', port = 8080}}))
rejects('http without port', config(nil, {{type = 'http', host = 'h'}}))

-- port ranges
for _, port in ipairs{0, -1, 65536, 70000, 1080.5, '1080'} do
    rejects('layer port ' .. tostring(port), config(nil, {{type = 'socks', host = 'h', port = port}}))
end
accepts('layer port 1', config(nil, {{type = 'socks', host = 'h', port = 1}}))
accepts('layer port 65535', config(nil, {{type = 'socks', host = 'h', port = 65535}}))

-- the server port may also be 0 (local socket)
accepts('server port 0', config({host = '/run/ircd.sock', port = 0}))
accepts('server port 65535', config({host = 'h', port = 65535}))
for _, port in ipairs{-1, 65536, 6667.5} do
    rejects('server port ' .. tostring(port), config({host = 'h', port = port}))
end

print('ok')
