-- Key and certificate helpers for services.
-- Each prints the NickServ command to register what it made or read.

local file <const> = require 'pl.file'
local log  <const> = require 'hub.runtime.log'
local task <const> = require 'hub.runtime.task'

local M = {}

local function pub64(k)
    return mybase64.to_base64(k:export().pub)
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
        help = 'Make an ECDSA key file and print its NickServ SET PUBKEY command',
        fn = function(_, filename)
            task.spawn('ecdsa_new', {owner = 'crypto'}, function(t)
                local cipher, password = pem_password(t)
                local k = myopenssl.gen_pkey('EC', 'P-256')
                k:set_param('point-format', 'compressed')
                assert(file.write(filename, k:to_private_pem(cipher, password) .. '\n' .. k:to_public_pem()))
                log.add('crypto', '/msg NickServ SET PUBKEY %s', pub64(k))
            end)
        end,
    },
    {
        name = 'ecdsa_fp', spec = '$g',
        help = "Print the NickServ SET PUBKEY command for an ECDSA key file",
        fn = function(_, filename)
            local pem = assert(file.read(filename))
            log.add('crypto', '/msg NickServ SET PUBKEY %s', pub64(myopenssl.read_pem(pem, true)))
        end,
    },
    {
        name = 'x25519_new', spec = '',
        help = 'Make an X25519 key and print it with its NickServ SET X25519-PUBKEY command',
        fn = function()
            local k = myopenssl.gen_pkey 'X25519'
            -- myopenssl has no get_raw_private(); the raw key is in export()
            log.add('crypto', 'Private key: %s', mybase64.to_base64(k:export().priv))
            log.add('crypto', '/msg NickServ SET X25519-PUBKEY %s', pub64(k))
        end,
    },
    {
        name = 'cert_new', spec = '$g',
        help = 'Make a self-signed client certificate and print its NickServ CERT ADD command',
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
                log.add('crypto', '/msg NickServ CERT ADD %s', cert_fingerprint(x509))
            end)
        end,
    },
    {
        name = 'cert_fp', spec = '$g',
        help = 'Print the NickServ CERT ADD command for a certificate file',
        fn = function(_, filename)
            local pem <const> = assert(file.read(filename))
            local x509 <close> = myopenssl.read_x509(pem)
            log.add('crypto', '/msg NickServ CERT ADD %s', cert_fingerprint(x509))
        end,
    },
}

return M
