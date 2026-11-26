/***
myopenssl module

Functions raise Lua errors on failure. An OpenSSL failure's message names
the failing call, followed by OpenSSL's queued errors, one per line.

@module myopenssl
*/

#include "myopenssl.hpp"

#include "bignum.hpp"
#include "digest.hpp"
#include "errors.hpp"
#include "pkey.hpp"
#include "x509.hpp"

#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/ui.h>
#include <openssl/x509.h>

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <algorithm>
#include <climits>
#include <cstddef>
#include <functional>

/***
Get a digest object by name

@function get_digest
@tparam string name OpenSSL digest name, such as "sha256"
@treturn digest digest
@raise "unknown digest 'name'" when OpenSSL has no such digest
*/

/***
Read a key from raw bytes.
@function read_raw
@tparam int type Type of key (constants in the myopenssl.types table)
@tparam bool private true for private key
@tparam string bytes raw key bytes
@treturn pkey parsed key
@raise openssl error on failure
*/

/***
Read a key from PEM format.

@function read_pem
@tparam string PEM PEM encoded key
@tparam bool private true for private key, false for a public key
@tparam[opt] string password PEM decryption password (default empty)
@treturn pkey parsed key
@raise openssl error on failure, including a wrong password
*/

/***
Generate a new key.

@function gen_pkey
@tparam string type "RSA", "EC", "X25519", "X448", "ED25519", "ED448" or "SM2"
@tparam[opt] integer|string arg RSA: key size in bits (required); EC: curve
name such as "P-256" (required); other types: unused
@treturn pkey new private key
@raise on an unknown type, or openssl error on failure
*/

/***
Load a key from an OpenSSL store, such as a file path or `file:` URI.
Returns the first key of the requested kind; items that fail to decode
are skipped.

@function pkey_from_store
@tparam string name store URI or path
@tparam bool private true for a private key, false for a public key
@tparam[opt] string password decryption password (default empty)
@treturn pkey key
@raise openssl error when the store can't be opened, or "no private key
found in 'name'" (or public) followed by any queued OpenSSL errors, such
as a wrong password
*/

/***
Make an arbitrary precision integer.

@function bignum
@tparam bignum|integer|string value a bignum is returned as-is; anything
else is converted with tostring and must be a whole decimal integer
@treturn bignum
@raise "bad bignum string" when the text isn't a decimal integer
*/

/***
Make a new, empty certificate.

@function new_x509
@treturn x509
@raise openssl error on failure
*/

/***
Read a certificate from PEM format.

@function read_x509
@tparam string PEM PEM encoded certificate
@tparam[opt] string password PEM password (default empty)
@treturn x509 parsed certificate
@raise openssl error on failure
*/

/***
Types for use with read_raw

@table types
@field EVP_PKEY_X25519 X25519 type
@field EVP_PKEY_ED25519 ED25519 type
@field EVP_PKEY_X448 X448 type
@field EVP_PKEY_ED448 ED448 type
*/

/***
Version number for x509:set_version meaning X.509 v3 (its value is 2)

@field X509_VERSION_3
*/

namespace {

/***
Generate random bytes

@function rand
@tparam integer length number of bytes to generate, 0 to INT_MAX
@tparam[opt] boolean private generation is for a private key (uses
OpenSSL's private generator)
@treturn string random bytes
@raise openssl error on failure
*/
auto l_rand(lua_State* const L) -> int
{
    auto const num = luaL_checkinteger(L, 1);
    luaL_argcheck(L, 0 <= num && num <= INT_MAX, 1, "out of range");
    auto const priv = lua_toboolean(L, 2);

    luaL_Buffer B;
    auto const buf = reinterpret_cast<unsigned char*>(luaL_buffinitsize(L, &B, num));

    auto const result = (priv ? RAND_priv_bytes : RAND_bytes)(buf, static_cast<int>(num));
    if (1 != result)
    {
        myopenssl::openssl_failure(L, priv ? "RAND_priv_bytes" : "RAND_bytes");
    }

    luaL_pushresultsize(&B, num);
    return 1;
}


/***
Byte-wise XOR of two strings. The shorter string is padded out with zero
bytes, so the result has the longer one's length.

@function xor
@tparam string input1
@tparam string input2
@treturn string input1 xor input2
*/
auto l_xor(lua_State* const L) -> int
{
    std::size_t l1, l2;
    auto const s1 = luaL_checklstring(L, 1, &l1);
    auto const s2 = luaL_checklstring(L, 2, &l2);

    auto const lc = std::min(l1, l2);
    auto const lt = std::max(l1, l2);

    luaL_Buffer B;
    auto const output = luaL_buffinitsize(L, &B, lt);

    std::transform(s1, s1 + lc, s2, output, std::bit_xor());

    if (l1 < l2) {
        std::copy(s2 + lc, s2 + l2, output + lc);
    } else {
        std::copy(s1 + lc, s1 + l1, output + lc);
    }

    luaL_pushresultsize(&B, lt);
    return 1;
}

} // namespace

extern "C" auto luaopen_myopenssl(lua_State* const L) -> int
{
    static luaL_Reg const LIB[]{
        {"get_digest", myopenssl::l_get_digest},
        {"read_raw", myopenssl::l_read_raw},
        {"read_pem", myopenssl::l_read_pem},
        {"gen_pkey", myopenssl::l_gen_pkey},
        {"bignum", myopenssl::l_bignum},
        {"new_x509", myopenssl::l_new_x509},
        {"read_x509", myopenssl::l_read_x509},
        {"pkey_from_store", myopenssl::l_pkey_from_store},
        {"rand", l_rand},
        {"xor", l_xor},
        {}
    };

    luaL_newlibtable(L, LIB);
    myopenssl::setfuncs(L, LIB);

    lua_createtable(L, 0, 4);
    lua_pushinteger(L, EVP_PKEY_X25519);
    lua_setfield(L, -2, "EVP_PKEY_X25519");
    lua_pushinteger(L, EVP_PKEY_ED25519);
    lua_setfield(L, -2, "EVP_PKEY_ED25519");
    lua_pushinteger(L, EVP_PKEY_X448);
    lua_setfield(L, -2, "EVP_PKEY_X448");
    lua_pushinteger(L, EVP_PKEY_ED448);
    lua_setfield(L, -2, "EVP_PKEY_ED448");
    lua_setfield(L, -2, "types");

    lua_pushinteger(L, X509_VERSION_3);
    lua_setfield(L, -2, "X509_VERSION_3");

    // OpenSSL's default method will lock-up the client UI
    UI_set_default_method(UI_null());

    return 1;
}
