-- Key and certificate helpers for services.
-- Each shows what it made or read in the detail pane (ui/details/keys.lua)
-- and logs the NickServ command to register it. A private key is shown
-- only in the pane, never logged.

local file <const> = require 'pl.file'
local log  <const> = require 'hub.runtime.log'
local task <const> = require 'hub.runtime.task'

local M = {}

local function pub64(k)
    return mybase64.to_base64(k:export().pub)
end

--- What a crypto command made or read.
---@class hub.Keys
---@field what string such as 'X25519 key'
---@field made boolean made now, rather than read from a file
---@field file string|nil
---@field encrypted boolean|nil the file's private key has a password
---@field public string|nil base64
---@field fingerprint string|nil hex SHA-512 of a certificate
---@field private string|nil base64, for a key that has no file
---@field commands string[] to send to services

-- Log each services command, with the record to reopen without its
-- private key, and show the whole record in the detail pane, when there
-- is a UI. Only the pane holds the private key, until it shows something
-- else. A route, unlike an event, reaches no plugin subscribers.
---@param keys hub.Keys
local function report(keys)
    local public = {}
    for k, v in pairs(keys) do
        if k ~= 'private' then public[k] = v end
    end
    for _, command in ipairs(keys.commands) do
        log.add_detail(nil, 'crypto', {kind = 'keys', data = public}, '%s', command)
    end
    local open = HUB.current.routes['ui.open_detail']
    if open then open('keys', nil, keys) end
end

local function cert_fingerprint(x509)
    local raw_fp <const> = x509:fingerprint(myopenssl.get_digest 'sha512')
    local fp <const> = {}
    for i = 1, #raw_fp do
        fp[i] = string.format('%02X', raw_fp:byte(i))
    end
    return table.concat(fp)
end

-- The key identifier of a public key: SHA-1 of its DER encoding
local function mk_key_id(pkey)
    return myopenssl.get_digest 'sha1':digest(pkey:export().pub)
end

-- Ask for a PEM password; an empty one leaves the key unencrypted. Both
-- cipher and password are nil then: to_private_pem rejects a password
-- without a cipher, so '' would make every unencrypted key fail.
local function pem_password(t)
    local password = t:prompt 'New private key PEM password'
    if password == nil then
        error('aborted', 0)
    end
    if password == '' then
        return nil, nil
    end
    return 'aes256', password
end

M.commands = {
    {
        name = 'ecdsa_new', spec = '$g',
        help = 'Make an ECDSA key file and show its NickServ SET PUBKEY command',
        fn = function(_, filename)
            task.spawn('ecdsa_new', {owner = 'crypto'}, function(t)
                local cipher, password = pem_password(t)
                local k = myopenssl.gen_pkey('EC', 'P-256')
                k:set_param('point-format', 'compressed')
                assert(file.write(filename, k:to_private_pem(cipher, password) .. '\n' .. k:to_public_pem()))
                local public = pub64(k)
                report {what = 'ECDSA P-256 key', made = true, file = filename, encrypted = cipher ~= nil,
                        public = public, commands = {'/msg NickServ SET PUBKEY ' .. public}}
            end)
        end,
    },
    {
        name = 'ecdsa_fp', spec = '$g',
        help = "Show the NickServ SET PUBKEY command for an ECDSA key file",
        fn = function(_, filename)
            local pem = assert(file.read(filename))
            local public = pub64(myopenssl.read_pem(pem, true))
            report {what = 'ECDSA key', made = false, file = filename,
                    public = public, commands = {'/msg NickServ SET PUBKEY ' .. public}}
        end,
    },
    {
        name = 'x25519_new', spec = '',
        help = 'Make an X25519 key and show it with its NickServ SET X25519-PUBKEY command',
        fn = function()
            local k = myopenssl.gen_pkey 'X25519'
            -- myopenssl has no get_raw_private(); the raw key is in export()
            local public = pub64(k)
            report {what = 'X25519 key', made = true, public = public,
                    private = mybase64.to_base64(k:export().priv),
                    commands = {'/msg NickServ SET X25519-PUBKEY ' .. public}}
        end,
    },
    {
        name = 'cert_new', spec = '$g',
        help = 'Make a self-signed client certificate and show its NickServ CERT ADD command',
        fn = function(_, filename)
            task.spawn('cert_new', {owner = 'crypto'}, function(t)
                local cipher, password = pem_password(t)
                local pkey <close> = myopenssl.gen_pkey 'ED25519'
                local key_id <const> = mk_key_id(pkey)
                local name <const> = {{'CN', 'snowcone'}}

                local x509 <close> = myopenssl.new_x509()
                x509:set_version(myopenssl.X509_VERSION_3)
                x509:set_serialNumber(0)
                x509:set_subjectName(name)
                x509:set_issuerName(name)
                x509:set_notBefore '19700101000000Z'
                x509:set_notAfter '20700101000000Z' -- NickServ handles revocation
                x509:set_pubkey(pkey)
                x509:add_subjectKeyIdentifier(key_id)
                x509:add_authorityKeyIdentifier(key_id)
                x509:add_caConstraint(true)
                x509:sign(pkey) -- must be last

                assert(file.write(filename, x509:export() .. '\n' .. pkey:to_private_pem(cipher, password)))
                local fp = cert_fingerprint(x509)
                report {what = 'Ed25519 certificate', made = true, file = filename, encrypted = cipher ~= nil,
                        fingerprint = fp, commands = {'/msg NickServ CERT ADD ' .. fp}}
            end)
        end,
    },
    {
        name = 'cert_fp', spec = '$g',
        help = 'Show the NickServ CERT ADD command for a certificate file',
        fn = function(_, filename)
            local pem <const> = assert(file.read(filename))
            local x509 <close> = myopenssl.read_x509(pem)
            local fp = cert_fingerprint(x509)
            report {what = 'certificate', made = false, file = filename,
                    fingerprint = fp, commands = {'/msg NickServ CERT ADD ' .. fp}}
        end,
    },
}

return M
