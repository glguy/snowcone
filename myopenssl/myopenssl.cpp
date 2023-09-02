#include "myopenssl.hpp"

#include "digest.hpp"
#include "pkey.hpp"

#include <openssl/evp.h>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

static luaL_Reg const LIB [] {
    {"get_digest", l_get_digest},
    {"read_raw", l_read_raw},
    {"read_pkey", l_read_pkey},
    {}
};

auto luaopen_myopenssl(lua_State * const L) -> int
{
    luaL_newlib(L, LIB);

    lua_pushnumber(L, EVP_PKEY_X25519);
    lua_setfield(L, -2, "EVP_PKEY_X25519");

    lua_pushnumber(L, EVP_PKEY_ED25519);
    lua_setfield(L, -2, "EVP_PKEY_ED25519");

    lua_pushnumber(L, EVP_PKEY_X448);
    lua_setfield(L, -2, "EVP_PKEY_X448");

    lua_pushnumber(L, EVP_PKEY_ED448);
    lua_setfield(L, -2, "EVP_PKEY_ED448");

    return 1;
}
