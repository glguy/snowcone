#include "digest.hpp"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include <openssl/evp.h>
#include <openssl/hmac.h>

#include <cstddef>

static luaL_Reg const DigestMethods[] {
    {"digest", [](auto const L)
    {
        // Process arguments
        auto const type = *static_cast<EVP_MD const**>(luaL_checkudata(L, 1, "digest"));
        std::size_t count;
        auto const data = luaL_checklstring(L, 2, &count);

        // Prepare the buffer
        luaL_Buffer B;
        auto const md = reinterpret_cast<unsigned char*>(luaL_buffinitsize(L, &B, EVP_MAX_MD_SIZE));

        // Perform the digest
        unsigned int size;
        auto const success = EVP_Digest(data, count, md, &size, type, nullptr);

        if (0 >= success)
        {
            luaL_error(L, "EVP_Digest(%d)", success);
            return 0;
        }

        // Push results
        luaL_pushresultsize(&B, size);
        return 1;
    }},

    {"hmac", [](auto const L)
    {
        auto const type = *static_cast<EVP_MD const**>(luaL_checkudata(L, 1, "digest"));
        std::size_t data_len;
        auto const data = reinterpret_cast<unsigned char const*>(luaL_checklstring(L, 2, &data_len));
        std::size_t key_len;
        auto const key = luaL_checklstring(L, 3, &key_len);

        luaL_Buffer B;
        auto const md = reinterpret_cast<unsigned char*>(luaL_buffinitsize(L, &B, EVP_MAX_MD_SIZE));

        unsigned int md_len;
        if (nullptr == HMAC(type, key, key_len, data, data_len, md, &md_len))
        {
            luaL_error(L, "HMAC");
            return 0;
        }

        luaL_pushresultsize(&B, md_len);
        return 1;
    }},

    {}
};

auto l_get_digest(lua_State * const L) -> int
{
    // Process arguments
    auto const name = luaL_checkstring(L, 1);

    // Lookup digest
    auto const digest = EVP_get_digestbyname(name);
    if (digest == nullptr)
    {
        luaL_error(L, "EVP_get_digestbyname");
        return 0;
    }

    // Allocate userdata
    auto const digestPtr = static_cast<EVP_MD const**>(lua_newuserdatauv(L, sizeof digest, 0));
    *digestPtr = digest;

    // Configure userdata's metatable
    if (luaL_newmetatable(L, "digest"))
    {
        luaL_newlibtable(L, DigestMethods);
        luaL_setfuncs(L, DigestMethods, 0);
        lua_setfield(L, -2, "__index");
    }
    lua_setmetatable(L, -2);

    return 1;
}
