/***
myopenssl module

@module myopenssl
*/

#include "myopenssl.hpp"

#include "bignum.hpp"
#include "digest.hpp"
#include "pkey.hpp"
#include "x509.hpp"

#include <openssl/evp.h>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

/***
Get a digest object by name

@function get_digest
@tparam string name
@treturn digest digest
@raise openssl error on failure
*/

/***
Read a key from raw bytes.
@function read_raw
@tparam int type Type of key (constants stored on myopenssl module)
@tparam bool private true for private key
@tparam string bytes raw key bytes
@treturn pkey parsed key
@raise openssl error on failure
*/

/***
Read a key from PEM format.

@function read_pkey
@tparam string PEM PEM encoded key
@tparam bool private true for private key
@tparam[opt] string password PEM decryption password
@treturn pkey parsed key
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

extern "C" auto luaopen_myopenssl(lua_State * const L) -> int
{
    static luaL_Reg const LIB [] {
        {"get_digest", myopenssl::l_get_digest},
        {"read_raw", myopenssl::l_read_raw},
        {"read_pem", myopenssl::l_read_pem},
        {"gen_pkey", myopenssl::l_gen_pkey},
        {"bignum", myopenssl::l_bignum},
        {"new_x509", myopenssl::l_new_x509},
        {}
    };

    luaL_newlib(L, LIB);

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

    return 1;
}
