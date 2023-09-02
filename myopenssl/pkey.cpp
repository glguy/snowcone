#include "pkey.hpp"
#include "invoke.hpp"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/rsa.h>

#include <cstddef>
#include <cstring>

namespace {

auto push_evp_pkey(lua_State * const L, EVP_PKEY * pkey) -> void;

luaL_Reg const PkeyMT[] {
    { "__gc", [](auto const L)
    {
        auto const pkeyPtr = static_cast<EVP_PKEY**>(luaL_checkudata(L, 1, "pkey"));
        EVP_PKEY_free(*pkeyPtr);
        *pkeyPtr = nullptr;
        return 0;
    }},

    {}
};

luaL_Reg const PkeyMethods[] {
    { "sign", [](auto const L)
    {
        auto const pkey = *static_cast<EVP_PKEY**>(luaL_checkudata(L, 1, "pkey"));
        std::size_t data_len;
        auto const data = reinterpret_cast<unsigned char const*>(luaL_checklstring(L, 2, &data_len));

        auto const ctx = EVP_PKEY_CTX_new(pkey, nullptr);
        if (nullptr == ctx)
        {
            luaL_error(L, "EVP_PKEY_CTX_new");
            return 0;
        }

        auto success = EVP_PKEY_sign_init(ctx);
        if (0 >= success)
        {
            EVP_PKEY_CTX_free(ctx);
            luaL_error(L, "EVP_PKEY_sign_init(%d)", success);
            return 0;
        }

        // Get the max output size
        std::size_t sig_len;
        success = EVP_PKEY_sign(ctx, nullptr, &sig_len, data, data_len);

        if (0 >= success)
        {
            EVP_PKEY_CTX_free(ctx);
            luaL_error(L, "EVP_PKEY_sign(%d)", success);
            return 0;
        }

        luaL_Buffer B;
        auto const sig = reinterpret_cast<unsigned char*>(luaL_buffinitsize(L, &B, sig_len));

        success = EVP_PKEY_sign(ctx, sig, &sig_len, data, data_len);
        EVP_PKEY_CTX_free(ctx);

        if (0 >= success)
        {
            luaL_error(L, "EVP_PKEY_sign(%d)", success);
            return 0;
        }

        luaL_pushresultsize(&B, sig_len);
        return 1;
    }},

    {"decrypt", [](auto const L)
    {
        auto const pkey = *static_cast<EVP_PKEY**>(luaL_checkudata(L, 1, "pkey"));
        std::size_t in_len;
        auto const in = reinterpret_cast<unsigned char const*>(luaL_checklstring(L, 2, &in_len));
        auto const format = luaL_optlstring(L, 3, "", nullptr);

        auto const ctx = EVP_PKEY_CTX_new(pkey, nullptr);
        if (nullptr == ctx)
        {
            luaL_error(L, "EVP_PKEY_CTX_new");
            return 0;
        }

        auto success = EVP_PKEY_decrypt_init(ctx);
        if (0 >= success)
        {
            EVP_PKEY_CTX_free(ctx);
            luaL_error(L, "EVP_PKEY_decrypt_init(%d)", success);
            return 0;
        }

        if (0 == strcmp("oaep", format))
        {
            success = EVP_PKEY_CTX_set_rsa_padding(ctx, RSA_PKCS1_OAEP_PADDING);
            if (0 >= success)
            {
                EVP_PKEY_CTX_free(ctx);
                luaL_error(L, "EVP_PKEY_CTX_set_rsa_padding(%d)", success);
                return 0;
            }
        }

        std::size_t out_len;
        success = EVP_PKEY_decrypt(ctx, nullptr, &out_len, in, in_len);
        if (0 >= success)
        {
            EVP_PKEY_CTX_free(ctx);
            luaL_error(L, "EVP_PKEY_decrypt(%d)", success);
            return 0;
        }

        luaL_Buffer B;
        auto const out = reinterpret_cast<unsigned char*>(luaL_buffinitsize(L, &B, out_len));

        success = EVP_PKEY_decrypt(ctx, out, &out_len, in, in_len);
        EVP_PKEY_CTX_free(ctx);

        if (0 >= success)
        {
            luaL_error(L, "EVP_PKEY_decrypt(%d)", success);
            return 0;
        }

        luaL_pushresultsize(&B, out_len);
        return 1;
    }},

    {"derive", [](auto const L)
    {
        auto const priv = *static_cast<EVP_PKEY**>(luaL_checkudata(L, 1, "pkey"));
        auto const pub = *static_cast<EVP_PKEY**>(luaL_checkudata(L, 2, "pkey"));

        auto const ctx = EVP_PKEY_CTX_new(priv, nullptr);
        if (nullptr == ctx)
        {
            luaL_error(L, "EVP_PKEY_CTX_new");
            return 0;
        }

        auto success = EVP_PKEY_derive_init(ctx);
        if (0 >= success)
        {
            EVP_PKEY_CTX_free(ctx);
            luaL_error(L, "EVP_PKEY_derive_init(%d)", success);
            return 0;
        }

        success = EVP_PKEY_derive_set_peer(ctx, pub);
        if (0 >= success)
        {
            EVP_PKEY_CTX_free(ctx);
            luaL_error(L, "EVP_PKEY_derive_set_peer(%d)", success);
            return 0;
        }

        std::size_t out_len;
        success = EVP_PKEY_derive(ctx, nullptr, &out_len);
        if (0 >= success)
        {
            EVP_PKEY_CTX_free(ctx);
            luaL_error(L, "EVP_PKEY_derive(%d)", success);
            return 0;
        }

        luaL_Buffer B;
        auto const out = reinterpret_cast<unsigned char*>(luaL_buffinitsize(L, &B, out_len));

        success = EVP_PKEY_derive(ctx, out, &out_len);
        EVP_PKEY_CTX_free(ctx);

        if (0 >= success)
        {
            luaL_error(L, "EVP_PKEY_derive(%d)", success);
            return 0;
        }

        luaL_pushresultsize(&B, out_len);
        return 1;
    }},

    {"get_raw_public", [](auto const L)
    {
        auto const pkey = *static_cast<EVP_PKEY**>(luaL_checkudata(L, 1, "pkey"));

        std::size_t out_len;
        auto success = EVP_PKEY_get_raw_public_key(pkey, nullptr, &out_len);
        if (0 >= success)
        {
            luaL_error(L, "EVP_PKEY_get_raw_public_key(%d)", success);
            return 0;
        }

        luaL_Buffer B;
        auto const out = reinterpret_cast<unsigned char*>(luaL_buffinitsize(L, &B, out_len));

        success = EVP_PKEY_get_raw_public_key(pkey, out, &out_len);
        if (0 >= success)
        {
            luaL_error(L, "EVP_PKEY_get_raw_public_key(%d)", success);
            return 0;
        }

        luaL_pushresultsize(&B, out_len);
        return 1;
    }},

    {}
};

auto push_evp_pkey(lua_State * const L, EVP_PKEY * pkey) -> void
{
    *static_cast<EVP_PKEY**>(lua_newuserdatauv(L, sizeof pkey, 0)) = pkey;
    if (luaL_newmetatable(L, "pkey"))
    {
        luaL_setfuncs(L, PkeyMT, 0);

        luaL_newlibtable(L, PkeyMethods);
        luaL_setfuncs(L, PkeyMethods, 0);
        lua_setfield(L, -2, "__index");
    }
    lua_setmetatable(L, -2);
}

} // namespace

auto l_read_raw(lua_State * const L) -> int
{
    auto const type = luaL_checknumber(L, 1);
    auto const priv = lua_toboolean(L, 2);
    std::size_t raw_len;
    auto const raw = reinterpret_cast<unsigned char const*>(luaL_checklstring(L, 3, &raw_len));

    auto const pkey = priv
        ? EVP_PKEY_new_raw_private_key(type, nullptr, raw, raw_len)
        : EVP_PKEY_new_raw_public_key(type, nullptr, raw, raw_len);
    if (nullptr == pkey)
    {
        luaL_pushfail(L);
        lua_pushstring(L, "EVP_PKEY_new_raw_private_key");
        return 2;
    }

    push_evp_pkey(L, pkey);
    return 1;
}

auto l_read_pkey(lua_State * const L) -> int
{
    std::size_t key_len;
    auto const key = luaL_checklstring(L, 1, &key_len);
    auto const priv = lua_toboolean(L, 2);
    std::size_t pass_len;
    auto const pass = luaL_optlstring(L, 3, "", &pass_len);

    auto cb = [pass, pass_len](char *buf, int size, int rwflag) -> int
    {
        if (size < pass_len)
        {
            return 0;
        }
        memcpy(buf, pass, pass_len);
        return pass_len;
    };

    auto const bio = BIO_new_mem_buf(key, key_len);
    if (nullptr == bio)
    {
        luaL_pushfail(L);
        lua_pushstring(L, "BIO_new_mem_buf");
        return 2;
    }

    auto const pkey
        = (priv ? PEM_read_bio_PrivateKey : PEM_read_bio_PUBKEY)
            (bio, nullptr, Invoke<decltype(cb)>::invoke, &cb);

    BIO_free_all(bio);

    if (nullptr == pkey)
    {
        luaL_pushfail(L);
        lua_pushstring(L, priv ? "PEM_read_bio_PrivateKey" : "PEM_read_bio_PUBKEY");
        return 2;
    }

    push_evp_pkey(L, pkey);
    return 1;
}
