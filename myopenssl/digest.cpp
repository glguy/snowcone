/***
digest object

@classmod digest
*/

#include "digest.hpp"
#include "errors.hpp"

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <openssl/evp.h>
#include <openssl/hmac.h>

#include <cstddef>

namespace myopenssl {

static char const digest_name[] = "EVP_MD*";

auto check_digest(lua_State* const L, int const arg) -> EVP_MD const*
{
    return *static_cast<EVP_MD const**>(luaL_checkudata(L, arg, digest_name));
}

namespace {

    luaL_Reg const DigestMethods[]{

        /***
        Compute digest on input text

        @function digest:digest
        @tparam string data data to digest
        @treturn string digest bytes
        @raise openssl error on failure
        */
        {"digest", [](auto const L) {
             // Process arguments
             auto const type = check_digest(L, 1);
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
                 openssl_failure(L, "EVP_Digest");
             }

             // Push results
             luaL_pushresultsize(&B, size);
             return 1;
         }},

        /***
        Compute HMAC given data and key

        @function digest:hmac
        @tparam string data data to digest
        @tparam string key secret key
        @treturn string digest bytes
        @raise openssl error on failure
        */
        {"hmac", [](auto const L) {
             auto const type = check_digest(L, 1);
             std::size_t data_len;
             auto const data = reinterpret_cast<unsigned char const*>(luaL_checklstring(L, 2, &data_len));
             std::size_t key_len;
             auto const key = luaL_checklstring(L, 3, &key_len);

             luaL_Buffer B;
             auto const md = reinterpret_cast<unsigned char*>(luaL_buffinitsize(L, &B, EVP_MAX_MD_SIZE));

             unsigned int md_len;
             if (nullptr == HMAC(type, key, key_len, data, data_len, md, &md_len))
             {
                 openssl_failure(L, "HMAC");
             }

             luaL_pushresultsize(&B, md_len);
             return 1;
         }},

        {"size", [](auto const L) {
             auto const digest = check_digest(L, 1);
             lua_pushinteger(L, EVP_MD_get_size(digest));
             return 1;
         }},

        {"pbkdf2", [](auto const L) {
             auto const digest = check_digest(L, 1);
             std::size_t passlen;
             auto const pass = luaL_checklstring(L, 2, &passlen);
             std::size_t saltlen;
             auto const salt = reinterpret_cast<unsigned char const*>(luaL_checklstring(L, 3, &saltlen));
             auto const iter = luaL_checkinteger(L, 4);
             auto const keylen = luaL_checkinteger(L, 5);

             luaL_Buffer B;
             auto const out = reinterpret_cast<unsigned char*>(luaL_buffinitsize(L, &B, keylen));

             auto const result = PKCS5_PBKDF2_HMAC(pass, passlen, salt, saltlen, iter, digest, keylen, out);
             if (result == 0)
             {
                 openssl_failure(L, "PKCS5_PBKDF2_HMAC");
             }

             luaL_pushresultsize(&B, keylen);
             return 1;
         }},

        {}
    };

    static auto push_digest(lua_State* const L, EVP_MD const* const digest) -> void
    {
        // Allocate userdata
        auto const digestPtr = static_cast<EVP_MD const**>(lua_newuserdatauv(L, sizeof digest, 0));
        *digestPtr = digest;

        // Configure userdata's metatable
        if (luaL_newmetatable(L, digest_name))
        {
            luaL_newlibtable(L, DigestMethods);
            luaL_setfuncs(L, DigestMethods, 0);
            lua_setfield(L, -2, "__index");
        }
        lua_setmetatable(L, -2);
    }

} // namespace

auto l_get_digest(lua_State* const L) -> int
{
    // Process arguments
    auto const name = luaL_checkstring(L, 1);

    // Lookup digest
    auto const digest = EVP_get_digestbyname(name);
    if (digest == nullptr)
    {
        openssl_failure(L, "EVP_get_digestbyname");
    }

    push_digest(L, digest);

    return 1;
}

} // namespace myopenssl
