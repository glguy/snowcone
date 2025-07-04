/***
myopenssl module

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
#include <cstddef>

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

namespace {

/***
Generate random bytes

@function rand
@tparam integer length number of bytes to generate
@tparam boolean private generation is for a private key
@treturn string random bytes
*/
auto l_rand(lua_State* const L) -> int
{
    auto const num = luaL_checkinteger(L, 1);
    auto const priv = lua_toboolean(L, 2);

    luaL_Buffer B;
    auto const buf = reinterpret_cast<unsigned char*>(luaL_buffinitsize(L, &B, num));

    auto const result = (priv ? RAND_priv_bytes : RAND_bytes)(buf, num);
    if (1 != result)
    {
        myopenssl::openssl_failure(L, priv ? "RAND_priv_bytes" : "RAND_bytes");
    }

    luaL_pushresultsize(&B, num);
    return 1;
}


/**
 * @brief XORs two Lua strings of equal length and returns the result as a new string.
 *
 * Expects two string arguments on the Lua stack. The function performs a byte-wise XOR
 * of the two input strings. Short strings are padded out with zero bytes.
 *
 * param:   string input1
 * param:   string input2
 * return:  string input1 xor input2
 *
 * @param L Lua state
 * @return int 1 on success
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

    lua_pushinteger(L, X509_VERSION_3);
    lua_setfield(L, -2, "X509_VERSION_3");

    // OpenSSL's default method will lock-up the client UI
    UI_set_default_method(UI_null());

    return 1;
}
