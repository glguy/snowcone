/***
public/private key object

@classmod pkey
*/

#include "pkey.hpp"
#include "invoke.hpp"
#include "errors.hpp"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/rsa.h>

#include <cstddef>
#include <cstring>

namespace myopenssl {

namespace {

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

/***
@type pkey
*/

luaL_Reg const PkeyMethods[] {
    /***
    Sign a message using a private key
    @function pkey:sign
    @tparam string data to sign
    @treturn string signature bytes
    @raise openssl error on failure
    */
    { "sign", [](auto const L)
    {
        auto const pkey = *static_cast<EVP_PKEY**>(luaL_checkudata(L, 1, "pkey"));
        std::size_t data_len;
        auto const data = reinterpret_cast<unsigned char const*>(luaL_checklstring(L, 2, &data_len));

        auto const ctx = EVP_PKEY_CTX_new(pkey, nullptr);
        if (nullptr == ctx)
        {
            openssl_failure(L, "EVP_PKEY_CTX_new");
        }

        auto success = EVP_PKEY_sign_init(ctx);
        if (0 >= success)
        {
            EVP_PKEY_CTX_free(ctx);
            openssl_failure(L, "EVP_PKEY_sign_init");
        }

        // Get the max output size
        std::size_t sig_len;
        success = EVP_PKEY_sign(ctx, nullptr, &sig_len, data, data_len);

        if (0 >= success)
        {
            EVP_PKEY_CTX_free(ctx);
            openssl_failure(L, "EVP_PKEY_sign");
        }

        luaL_Buffer B;
        auto const sig = reinterpret_cast<unsigned char*>(luaL_buffinitsize(L, &B, sig_len));

        success = EVP_PKEY_sign(ctx, sig, &sig_len, data, data_len);
        EVP_PKEY_CTX_free(ctx);

        if (0 >= success)
        {
            openssl_failure(L, "EVP_PKEY_sign");
        }

        luaL_pushresultsize(&B, sig_len);
        return 1;
    }},

    /***
    Decrypt a message using a private key
    @function pkey:decrypt
    @tparam string ciphertext
    @tparam[opt] string format ("oaep" supported)
    @treturn string signature bytes
    @raise openssl error on failure
    */
    {"decrypt", [](auto const L)
    {
        auto const pkey = *static_cast<EVP_PKEY**>(luaL_checkudata(L, 1, "pkey"));
        std::size_t in_len;
        auto const in = reinterpret_cast<unsigned char const*>(luaL_checklstring(L, 2, &in_len));
        auto const format = luaL_optlstring(L, 3, "", nullptr);

        auto const ctx = EVP_PKEY_CTX_new(pkey, nullptr);
        if (nullptr == ctx)
        {
            openssl_failure(L, "EVP_PKEY_CTX_new");
        }

        auto success = EVP_PKEY_decrypt_init(ctx);
        if (0 >= success)
        {
            EVP_PKEY_CTX_free(ctx);
            openssl_failure(L, "EVP_PKEY_decrypt_init");
        }

        if (0 == strcmp("oaep", format))
        {
            success = EVP_PKEY_CTX_set_rsa_padding(ctx, RSA_PKCS1_OAEP_PADDING);
            if (0 >= success)
            {
                EVP_PKEY_CTX_free(ctx);
                openssl_failure(L, "EVP_PKEY_CTX_set_rsa_padding");
            }
        }

        std::size_t out_len;
        success = EVP_PKEY_decrypt(ctx, nullptr, &out_len, in, in_len);
        if (0 >= success)
        {
            EVP_PKEY_CTX_free(ctx);
            openssl_failure(L, "EVP_PKEY_decrypt");
        }

        luaL_Buffer B;
        auto const out = reinterpret_cast<unsigned char*>(luaL_buffinitsize(L, &B, out_len));

        success = EVP_PKEY_decrypt(ctx, out, &out_len, in, in_len);
        EVP_PKEY_CTX_free(ctx);

        if (0 >= success)
        {
            openssl_failure(L, "EVP_PKEY_decrypt");
        }

        luaL_pushresultsize(&B, out_len);
        return 1;
    }},

    /***
    Derive a shared secret given our private key and a given public key
    @function pkey:derive
    @tparam pkey public key
    @treturn string secret bytes
    @raise openssl error on failure
    */
    {"derive", [](auto const L)
    {
        auto const priv = *static_cast<EVP_PKEY**>(luaL_checkudata(L, 1, "pkey"));
        auto const pub = *static_cast<EVP_PKEY**>(luaL_checkudata(L, 2, "pkey"));

        auto const ctx = EVP_PKEY_CTX_new(priv, nullptr);
        if (nullptr == ctx)
        {
            openssl_failure(L, "EVP_PKEY_CTX_new");
        }

        auto success = EVP_PKEY_derive_init(ctx);
        if (0 >= success)
        {
            EVP_PKEY_CTX_free(ctx);
            openssl_failure(L, "EVP_PKEY_derive_init");
        }

        success = EVP_PKEY_derive_set_peer(ctx, pub);
        if (0 >= success)
        {
            EVP_PKEY_CTX_free(ctx);
            openssl_failure(L, "EVP_PKEY_derive_set_peer");
        }

        std::size_t out_len;
        success = EVP_PKEY_derive(ctx, nullptr, &out_len);
        if (0 >= success)
        {
            EVP_PKEY_CTX_free(ctx);
            openssl_failure(L, "EVP_PKEY_derive");
        }

        luaL_Buffer B;
        auto const out = reinterpret_cast<unsigned char*>(luaL_buffinitsize(L, &B, out_len));

        success = EVP_PKEY_derive(ctx, out, &out_len);
        EVP_PKEY_CTX_free(ctx);

        if (0 >= success)
        {
            openssl_failure(L, "EVP_PKEY_derive");
        }

        luaL_pushresultsize(&B, out_len);
        return 1;
    }},

    /***
    Return public key as raw bytes.
    
    @function get_raw_public
    @treturn string raw key bytes
    @raise openssl error on failure
    */
    {"get_raw_public", [](auto const L)
    {
        auto const pkey = *static_cast<EVP_PKEY**>(luaL_checkudata(L, 1, "pkey"));

        std::size_t out_len;
        auto success = EVP_PKEY_get_raw_public_key(pkey, nullptr, &out_len);
        if (0 >= success)
        {
            openssl_failure(L, "EVP_PKEY_get_raw_public_key");
        }

        luaL_Buffer B;
        auto const out = reinterpret_cast<unsigned char*>(luaL_buffinitsize(L, &B, out_len));

        success = EVP_PKEY_get_raw_public_key(pkey, out, &out_len);
        if (0 >= success)
        {
            openssl_failure(L, "EVP_PKEY_get_raw_public_key");
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
    auto const type = luaL_checkinteger(L, 1);
    auto const priv = lua_toboolean(L, 2);
    std::size_t raw_len;
    auto const raw = reinterpret_cast<unsigned char const*>(luaL_checklstring(L, 3, &raw_len));

    auto const pkey = priv
        ? EVP_PKEY_new_raw_private_key(type, nullptr, raw, raw_len)
        : EVP_PKEY_new_raw_public_key(type, nullptr, raw, raw_len);
    if (nullptr == pkey)
    {
        openssl_failure(L, "EVP_PKEY_new_raw_private_key");
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

    auto cb = [pass, pass_len](char *buf, int size, int) -> int
    {
        if (size < 0 || size_t(size) < pass_len)
        {
            return -1; // -1:error due to password not fitting
        }
        memcpy(buf, pass, pass_len);
        return pass_len;
    };

    auto const bio = BIO_new_mem_buf(key, key_len);
    if (nullptr == bio)
    {
        openssl_failure(L, "BIO_new_mem_buf");
    }

    auto const pkey
        = (priv ? PEM_read_bio_PrivateKey : PEM_read_bio_PUBKEY)
            (bio, nullptr, Invoke<decltype(cb)>::invoke, &cb);

    BIO_free_all(bio);

    if (nullptr == pkey)
    {
        openssl_failure(L, priv ? "PEM_read_bio_PrivateKey" : "PEM_read_bio_PUBKEY");
    }

    push_evp_pkey(L, pkey);
    return 1;
}

} // namespace myopenssl
