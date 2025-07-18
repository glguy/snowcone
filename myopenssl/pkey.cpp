/***
public/private key object

@classmod pkey
*/

#include "pkey.hpp"
#include "bignum.hpp"
#include "errors.hpp"
#include "invoke.hpp"

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/store.h>
#include <openssl/rsa.h>
#include <openssl/ui.h>

#include <cstddef>
#include <cstring>
#include <string_view>

namespace myopenssl {

static char const pkey_name[] = "EVP_PKEY*";

auto check_pkey(lua_State* const L, int const arg) -> EVP_PKEY*
{
    auto const pkey = *static_cast<EVP_PKEY**>(luaL_checkudata(L, arg, pkey_name));
    luaL_argcheck(L, nullptr != pkey, arg, "pkey already closed");
    return pkey;
}

namespace {

    auto l_gc(lua_State* const L) -> int
    {
        auto const pkeyPtr = static_cast<EVP_PKEY**>(luaL_checkudata(L, 1, pkey_name));
        EVP_PKEY_free(*pkeyPtr);
        *pkeyPtr = nullptr;
        return 0;
    }

    luaL_Reg const X509MT[]{
        {"__gc", l_gc},
        {"__close", l_gc},
        {}
    };

    /***
    @type pkey
    */

    luaL_Reg const X509Methods[]{
        /***
        Sign a message using a private key
        @function pkey:sign
        @tparam string data to sign
        @treturn string signature bytes
        @raise openssl error on failure
        */
        {"sign", [](auto const L) {
             auto const pkey = check_pkey(L, 1);
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
        {"decrypt", [](auto const L) {
             auto const pkey = check_pkey(L, 1);
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
        {"derive", [](auto const L) {
             auto const priv = check_pkey(L, 1);
             auto const pub = check_pkey(L, 2);

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

        {"to_private_pem", [](auto const L) {
             auto const pkey = check_pkey(L, 1);
             auto const cipher_name = luaL_optlstring(L, 2, nullptr, nullptr);
             std::size_t pass_len;
             auto const pass = reinterpret_cast<unsigned char const*>(luaL_optlstring(L, 3, nullptr, &pass_len));

             if (nullptr == cipher_name && nullptr != pass)
             {
                 return luaL_argerror(L, 2, "missing cipher");
             }

             if (nullptr != cipher_name && nullptr == pass)
             {
                 return luaL_argerror(L, 3, "missing password");
             }

             EVP_CIPHER const* cipher = nullptr;
             if (nullptr != cipher_name)
             {
                 cipher = EVP_get_cipherbyname(cipher_name);
                 if (nullptr == cipher)
                 {
                     openssl_failure(L, "EVP_get_cipherbyname");
                 }
             }

             auto const bio = BIO_new(BIO_s_mem());
             if (nullptr == bio)
             {
                 openssl_failure(L, "BIO_new");
             }

             if (0 == PEM_write_bio_PrivateKey(bio, pkey, cipher, pass, pass_len, nullptr, nullptr))
             {
                 BIO_free_all(bio);
                 openssl_failure(L, "PEM_write_bio_PrivateKey");
             }
             char* data;
             auto const len = BIO_get_mem_data(bio, &data);
             lua_pushlstring(L, data, len);
             BIO_free_all(bio);
             return 1;
         }},

        {"to_public_pem", [](auto const L) {
             auto const pkey = check_pkey(L, 1);
             auto const bio = BIO_new(BIO_s_mem());
             if (nullptr == bio)
             {
                 openssl_failure(L, "BIO_new");
             }
             if (0 == PEM_write_bio_PUBKEY(bio, pkey))
             {
                 BIO_free_all(bio);
                 openssl_failure(L, "PEM_write_bio_PUBKEY");
             }
             char* data;
             auto const len = BIO_get_mem_data(bio, &data);
             lua_pushlstring(L, data, len);
             BIO_free_all(bio);
             return 1;
         }},

        {"export", [](auto const L) {
             auto const pkey = check_pkey(L, 1);

             auto const cb = [L](OSSL_PARAM const* const params) {
                 for (auto cursor = params; cursor->key; cursor++)
                 {
                     switch (cursor->data_type)
                     {
                     case OSSL_PARAM_UNSIGNED_INTEGER:
                     case OSSL_PARAM_INTEGER: {
                         auto r = push_bignum(L);
                         if (0 == OSSL_PARAM_get_BN(cursor, &r))
                         {
                             return 0; // failure
                         }
                         break;
                     }
                     default:
                         lua_pushlstring(L, reinterpret_cast<char const*>(cursor->data), cursor->data_size);
                         break;
                     }
                     lua_setfield(L, -2, cursor->key);
                 }
                 return 1; // success
             };

             lua_newtable(L);
             using Invoker = Invoke<decltype(cb)>;
             auto const success = EVP_PKEY_export(pkey, EVP_PKEY_KEYPAIR, Invoker::invoke, Invoker::prep(cb));
             if (0 == success)
             {
                 openssl_failure(L, "EVP_PKEY_export");
             }
             return 1;
         }},

        {"set_param", [](auto const L) {
             auto const pkey = check_pkey(L, 1);
             auto const name = luaL_checkstring(L, 2);

             auto const settable = EVP_PKEY_settable_params(pkey);
             if (nullptr == settable)
             {
                 openssl_failure(L, "EVP_PKEY_settable_params");
             }

             auto const param = OSSL_PARAM_locate_const(settable, name);
             if (nullptr == param)
             {
                 return luaL_error(L, "unknown parameter %s", name);
             }

             switch (param->data_type)
             {
             default:
                 luaL_error(L, "type not supported %d", param->data_type);
             case OSSL_PARAM_UTF8_STRING: {
                 auto const str = luaL_checkstring(L, 3);
                 auto const success = EVP_PKEY_set_utf8_string_param(pkey, name, str);
                 if (not success)
                 {
                     openssl_failure(L, "EVP_PKEY_set_utf8_string_param");
                 }
                 return 0;
             }
             case OSSL_PARAM_OCTET_STRING: {
                 std::size_t len;
                 auto const str = reinterpret_cast<unsigned char const*>(luaL_checklstring(L, 3, &len));
                 auto const success = EVP_PKEY_set_octet_string_param(pkey, name, str, len);
                 if (not success)
                 {
                     openssl_failure(L, "EVP_PKEY_set_octet_string_param");
                 }
                 return 0;
             }
             case OSSL_PARAM_UNSIGNED_INTEGER:
             case OSSL_PARAM_INTEGER: {
                 auto const n = luaL_checkinteger(L, 3);
                 auto const success = EVP_PKEY_set_int_param(pkey, name, n);
                 if (not success)
                 {
                     openssl_failure(L, "EVP_PKEY_set_octet_string_param");
                 }
                 return 0;
             }
             }
         }},

        {}
    };

} // namespace

auto push_evp_pkey(lua_State* const L, EVP_PKEY* pkey) -> void
{
    *static_cast<EVP_PKEY**>(lua_newuserdatauv(L, sizeof pkey, 0)) = pkey;
    if (luaL_newmetatable(L, pkey_name))
    {
        luaL_setfuncs(L, X509MT, 0);

        luaL_newlibtable(L, X509Methods);
        luaL_setfuncs(L, X509Methods, 0);
        lua_setfield(L, -2, "__index");
    }
    lua_setmetatable(L, -2);
}

auto l_read_raw(lua_State* const L) -> int
{
    auto const type = luaL_checkinteger(L, 1);
    auto const priv = lua_toboolean(L, 2);
    std::size_t raw_len;
    auto const raw = reinterpret_cast<unsigned char const*>(luaL_checklstring(L, 3, &raw_len));

    auto const pkey = (priv ? EVP_PKEY_new_raw_private_key : EVP_PKEY_new_raw_public_key)(type, nullptr, raw, raw_len);
    if (nullptr == pkey)
    {
        openssl_failure(L, priv ? "EVP_PKEY_new_raw_private_key" : "EVP_PKEY_new_raw_public_key");
    }

    push_evp_pkey(L, pkey);
    return 1;
}

auto l_read_pem(lua_State* const L) -> int
{
    std::size_t key_len;
    auto const key = luaL_checklstring(L, 1, &key_len);
    auto const priv = lua_toboolean(L, 2);
    std::size_t pass_len;
    auto const pass = luaL_optlstring(L, 3, "", &pass_len);

    auto const cb = [pass, pass_len](char* const buf, int const size, int) -> int {
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

    using Invoker = Invoke<decltype(cb)>;
    auto const pkey
        = (priv ? PEM_read_bio_PrivateKey : PEM_read_bio_PUBKEY)(bio, nullptr, Invoker::invoke, Invoker::prep(cb));

    BIO_free_all(bio);

    if (nullptr == pkey)
    {
        openssl_failure(L, priv ? "PEM_read_bio_PrivateKey" : "PEM_read_bio_PUBKEY");
    }

    push_evp_pkey(L, pkey);
    return 1;
}

auto l_gen_pkey(lua_State* const L) -> int
{
    auto const type = luaL_checkstring(L, 1);
    EVP_PKEY* pkey;

    if (0 == strcmp("RSA", type))
    {
        std::size_t const size = luaL_checkinteger(L, 2);
        pkey = EVP_PKEY_Q_keygen(nullptr, nullptr, type, size);
    }
    else if (0 == strcmp("EC", type))
    {
        auto const curve = luaL_checkstring(L, 2);
        pkey = EVP_PKEY_Q_keygen(nullptr, nullptr, type, curve);
    }
    else if (0 == strcmp("X25519", type) || 0 == strcmp("X448", type) || 0 == strcmp("ED25519", type) || 0 == strcmp("ED448", type) || 0 == strcmp("SM2", type))
    {
        pkey = EVP_PKEY_Q_keygen(nullptr, nullptr, type);
    }
    else
    {
        return luaL_error(L, "Unknown key type");
    }

    if (nullptr == pkey)
    {
        openssl_failure(L, "EVP_PKEY_Q_keygen");
    }

    push_evp_pkey(L, pkey);
    return 1;
}

auto l_pkey_from_store(lua_State * const L) -> int
{
    auto const key_name = luaL_checkstring(L, 1);
    auto const priv = lua_toboolean(L, 2);
    std::size_t pass_len;
    auto const pass = luaL_optlstring(L, 3, "", &pass_len);

    auto const cb = [pass, pass_len](char * const buf, int const size, int) -> int
    {
        if (size < 0 || size_t(size) < pass_len)
        {
            return -1; // -1:error due to password not fitting
        }
        memcpy(buf, pass, pass_len);
        return pass_len;
    };
    using Invoker = Invoke<decltype(cb)>;
    auto const ui_method = UI_UTIL_wrap_read_pem_callback(Invoker::invoke, 0);
    auto const store = OSSL_STORE_open(key_name, ui_method, Invoker::prep(cb), nullptr, nullptr);
    if (nullptr == store)
    {
        UI_destroy_method(ui_method);
        openssl_failure(L, "OSSL_STORE_open");
    }

    EVP_PKEY* pkey = nullptr;
    while (auto const info = OSSL_STORE_load(store)) {
        auto const ty = OSSL_STORE_INFO_get_type(info);
        if (priv && OSSL_STORE_INFO_PKEY == ty)
        {
            pkey = OSSL_STORE_INFO_get1_PKEY(info);
        }
        else if (not priv && OSSL_STORE_INFO_PUBKEY == ty)
        {
            pkey = OSSL_STORE_INFO_get1_PUBKEY(info);
        }
        OSSL_STORE_INFO_free(info);
        if (pkey) break;
    }

    OSSL_STORE_close(store);
    UI_destroy_method(ui_method);

    if (nullptr == pkey)
    {
        luaL_error(L, "key not found");
    }

    push_evp_pkey(L, pkey);
    return 1;
}

} // namespace openssl
