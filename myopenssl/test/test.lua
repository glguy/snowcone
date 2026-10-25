local myopenssl = require 'myopenssl'

assert(not pcall(myopenssl.get_digest, 'xyz'))

local sha256 = myopenssl.get_digest 'sha256'

assert(
    '\xba\x78\x16\xbf\x8f\x01\xcf\xea\x41\x41\x40\xde\x5d\xae\x22\x23\z
     \xb0\x03\x61\xa3\x96\x17\x7a\x9c\xb4\x10\xff\x61\xf2\x00\x15\xad'
    ==
    sha256:digest 'abc'
)

assert(
    '\xb0\x34\x4c\x61\xd8\xdb\x38\x53\x5c\xa8\xaf\xce\xaf\x0b\xf1\x2b\z
     \x88\x1d\xc2\x00\xc9\x83\x3d\xa7\x26\xe9\x37\x6c\x2e\x32\xcf\xf7'
    ==
    sha256:hmac('Hi There', '\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b')
)

assert(not pcall(myopenssl.read_raw, myopenssl.types.EVP_PKEY_X25519, true, ''))

do
    local priv_key_raw =
        "\x40\x37\xf1\x1e\x67\xe1\x8d\x2a\x01\x31\x25\x7d\x7a\xc5\x43\xe3\z
        \x17\xed\x6a\x92\xe7\x90\xe0\xc1\x55\x8d\xe8\xdc\x24\xfa\xbd\x5a"
    local pub_key_raw =
        "\xc8\x5b\x24\x85\x07\x76\x25\x69\x36\x2f\x93\x2c\x2f\x29\xaf\x22\z
        \xa5\x03\x4c\xc4\xcb\xb3\x90\x4e\x27\xd3\xe5\x5b\xbd\x05\x9a\x7c"
    local priv_key = myopenssl.read_raw(myopenssl.types.EVP_PKEY_X25519, true, priv_key_raw)
    local pub_key = myopenssl.read_raw(myopenssl.types.EVP_PKEY_X25519, false, pub_key_raw)
    assert(priv_key:export().pub == pub_key_raw)
end

do
    local priv_key_raw =
        "\x40\x37\xf1\x1e\x67\xe1\x8d\x2a\x01\x31\x25\x7d\x7a\xc5\x43\xe3\z
        \x17\xed\x6a\x92\xe7\x90\xe0\xc1\x55\x8d\xe8\xdc\x24\xfa\xbd\x5a"
    local priv_key = myopenssl.read_raw(myopenssl.types.EVP_PKEY_ED25519, true, priv_key_raw)
    local pub_key = myopenssl.read_raw(myopenssl.types.EVP_PKEY_ED25519, false, priv_key:export().pub)
    local tbs = 'Hello world'
    local sig = priv_key:digest_sign(nil, tbs)
    print(sig)
    assert(pub_key:digest_verify(nil, sig, tbs))
end



local pem = io.open('test/rsa.pem'):read('a')
local priv = myopenssl.read_pem(pem, true)
priv:sign('a message') -- just make sure it doesn't blow up

pem = io.open('test/encrsa.pem'):read('a')
myopenssl.read_pem(pem, true, 'password')

-- Regressions from the S3 review (F-101 to F-109)
local function fails(pattern, f, ...)
    local ok, err = pcall(f, ...)
    assert(not ok, 'expected failure: ' .. pattern)
    assert(string.find(err, pattern, 1, true), err)
end

local closed = myopenssl.bignum(5)
getmetatable(closed).__close(closed)
assert(pcall(getmetatable(closed).__gc, closed))

local seven = myopenssl.bignum(7)
assert(rawequal(seven, myopenssl.bignum(seven)))
fails('bad bignum string', myopenssl.bignum, '')
fails('out of range', function() return seven << ((1 << 32) + 1) end)
assert(tostring(seven << 1) == '14')

local sha256 = myopenssl.get_digest 'sha256'
fails("unknown digest 'nope'", myopenssl.get_digest, 'nope')
fails('out of range', sha256.pbkdf2, sha256, 'p', 's', (1 << 32) + 1, 32)
fails('out of range', myopenssl.rand, -1)

local ed = myopenssl.gen_pkey 'ED25519'
assert(not ed:digest_verify(nil, string.rep('\0', 64), 'msg'))
-- the failed verification must not leak into the next error
local ok, err = pcall(myopenssl.get_digest, 'nope')
assert(not ok and not err:find('\n'), err)

local x509 = myopenssl.new_x509()
fails('invalid field name', x509.set_subjectName, x509, {{'CNN', 'typo'}})
fails('list of {field, value} pairs', x509.set_subjectName, x509, {CN = 'a'})
fails('name entry 2', x509.set_subjectName, x509, {{'CN', 'a'}, {'O'}})
assert(next(x509:get_subjectName()) == nil)
-- order and repeats are kept; fields round-trip by short name or OID
x509:set_subjectName{{'O', 'b'}, {'OU', 'x'}, {'OU', 'y'}, {'commonName', 'a'}, {'1.2.3.4', 'z'}}
local got = {}
for i, entry in ipairs(x509:get_subjectName()) do got[i] = entry[1] .. '=' .. entry[2] end
assert(table.concat(got, ',') == 'O=b,OU=x,OU=y,CN=a,1.2.3.4=z', table.concat(got, ','))

fails('unknown padding', priv.decrypt, priv, 'x', 'OAEP')
assert(priv:decrypt(priv:encrypt('hi', 'oaep'), 'oaep') == 'hi')

fails("no private key found in 'test/encrsa.pem'", myopenssl.pkey_from_store, 'test/encrsa.pem', true, 'wrong')
assert(myopenssl.pkey_from_store('test/encrsa.pem', true, 'password'))

print 'ok'
