/***
public/private key object, from myopenssl.read_pem, read_raw, gen_pkey,
pkey_from_store or x509:get_pubkey

Closing (or collecting) a key frees it, and later use raises
"pkey already closed".

@classmod pkey
*/

#include "pkey.hpp"
#include "bignum.hpp"
#include "digest.hpp"
#include "errors.hpp"
#include "invoke.hpp"
#include "owned.hpp"

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/params.h>
#include <openssl/pem.h>
#include <openssl/rsa.h>
#include <openssl/store.h>
#include <openssl/ui.h>

#include <climits>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string_view>

namespace myopenssl {

/// Registry name of the pkey metatable
static char const pkey_name[] = "EVP_PKEY*";

auto check_pkey(lua_State* const L, int const arg) -> EVP_PKEY*
{
    auto const pkey = *static_cast<EVP_PKEY**>(luaL_checkudata(L, arg, pkey_name));
    luaL_argcheck(L, nullptr != pkey, arg, "pkey already closed");
    return pkey;
}

auto test_pkey(lua_State* const L, int const arg) -> EVP_PKEY*
{
    auto const pkey = static_cast<EVP_PKEY**>(luaL_testudata(L, arg, pkey_name));
    return pkey ? *pkey : nullptr;
}

namespace {

    using PkeyCtx = Owned<EVP_PKEY_CTX, EVP_PKEY_CTX_free>;
    using MdCtx = Owned<EVP_MD_CTX, EVP_MD_CTX_free>;
    using Bio = Owned<BIO, BIO_free_all>;
    using Params = Owned<OSSL_PARAM, OSSL_PARAM_free>;

    /// __gc and __close: free the key and mark the userdata closed. Safe to
    /// run again on a closed key.
    auto l_gc(lua_State* const L) -> int
    {
        auto const pkeyPtr = static_cast<EVP_PKEY**>(luaL_checkudata(L, 1, pkey_name));
        EVP_PKEY_free(*pkeyPtr);
        *pkeyPtr = nullptr;
        return 0;
    }

    /// Push a bignum with value
    auto push_int64(lua_State* const L, std::int64_t const value) -> void
    {
        auto const r = new_bignum(L);
        // the magnitude, as unsigned arithmetic, so INT64_MIN works too
        auto magnitude = value < 0 ? 0 - static_cast<std::uint64_t>(value) : static_cast<std::uint64_t>(value);
        unsigned char bytes[8];
        for (int i = 7; i >= 0; i--)
        {
            bytes[i] = static_cast<unsigned char>(magnitude & 0xff);
            magnitude >>= 8;
        }
        if (nullptr == BN_bin2bn(bytes, sizeof bytes, r))
        {
            openssl_failure(L, "BN_bin2bn");
        }
        BN_set_negative(r, value < 0);
    }

    /// Pkey metamethods, registered without the dispatch boundary
    luaL_Reg const PkeyMT[]{
        {"__gc", l_gc},
        {"__close", l_gc},
        {}
    };

    /***
    @type pkey
    */

    /// Pkey methods, the metatable's __index
    luaL_Reg const PkeyMethods[]{
        /***
        Sign data with a private key directly (no digest: data is
        typically already a digest)
        @function pkey:sign
        @tparam string data to sign
        @treturn string signature bytes
        @raise openssl error on failure
        */
        {"sign", [](auto const L) {
             auto const pkey = check_pkey(L, 1);
             std::size_t data_len;
             auto const data = reinterpret_cast<unsigned char const*>(luaL_checklstring(L, 2, &data_len));

             auto& ctx = PkeyCtx::push(L);
             ctx = EVP_PKEY_CTX_new(pkey, nullptr);
             if (nullptr == ctx)
             {
                 openssl_failure(L, "EVP_PKEY_CTX_new");
             }

             auto success = EVP_PKEY_sign_init(ctx);
             if (0 >= success)
             {
                 PkeyCtx::reset(ctx);
                 openssl_failure(L, "EVP_PKEY_sign_init");
             }

             // Get the max output size
             std::size_t sig_len;
             success = EVP_PKEY_sign(ctx, nullptr, &sig_len, data, data_len);

             if (0 >= success)
             {
                 PkeyCtx::reset(ctx);
                 openssl_failure(L, "EVP_PKEY_sign");
             }

             luaL_Buffer B;
             auto const sig = reinterpret_cast<unsigned char*>(luaL_buffinitsize(L, &B, sig_len));

             success = EVP_PKEY_sign(ctx, sig, &sig_len, data, data_len);
             PkeyCtx::reset(ctx);

             if (0 >= success)
             {
                 openssl_failure(L, "EVP_PKEY_sign");
             }

             luaL_pushresultsize(&B, sig_len);
             return 1;
         }},

        /***
        Sign a message using a private key, digesting it first
        @function pkey:digest_sign
        @tparam[opt] digest digest to use; nil for the key type's default,
        and required to be nil for ED25519 and ED448
        @tparam string data to sign
        @treturn string signature bytes
        @raise openssl error on failure
        */
        {"digest_sign", [](auto const L) {
             auto const pkey = check_pkey(L, 1);
             auto const md = luaL_opt(L, check_digest, 2, nullptr);
             std::size_t data_len;
             auto const data = reinterpret_cast<unsigned char const*>(luaL_checklstring(L, 3, &data_len));

             auto& ctx = MdCtx::push(L);
             ctx = EVP_MD_CTX_new();
             if (nullptr == ctx)
             {
                 openssl_failure(L, "EVP_MD_CTX_new");
             }

             auto success = EVP_DigestSignInit(ctx, nullptr, md, nullptr, pkey);
             if (0 >= success)
             {
                 MdCtx::reset(ctx);
                 openssl_failure(L, "EVP_DigestSignInit");
             }

             // Get the max output size
             std::size_t sig_len;
             success = EVP_DigestSign(ctx, nullptr, &sig_len, data, data_len);

             if (0 >= success)
             {
                 MdCtx::reset(ctx);
                 openssl_failure(L, "EVP_DigestSign");
             }

             luaL_Buffer B;
             auto const sig = reinterpret_cast<unsigned char*>(luaL_buffinitsize(L, &B, sig_len));

             success = EVP_DigestSign(ctx, sig, &sig_len, data, data_len);
             MdCtx::reset(ctx);

             if (0 >= success)
             {
                 openssl_failure(L, "EVP_DigestSign");
             }

             luaL_pushresultsize(&B, sig_len);
             return 1;
         }},

        /***
        Verify a message signature using a public key
        @function pkey:digest_verify
        @tparam[opt] digest digest to use; nil as for digest_sign
        @tparam string signature
        @tparam string signed data
        @treturn boolean whether the signature verifies: false for a
        mismatch and for a malformed signature alike
        @raise openssl error when the key or digest can't verify at all
        */
        {"digest_verify", [](auto const L) {
             auto const pkey = check_pkey(L, 1);
             auto const md = luaL_opt(L, check_digest, 2, nullptr);
             std::size_t sig_len;
             auto const sig = reinterpret_cast<unsigned char const*>(luaL_checklstring(L, 3, &sig_len));
             std::size_t data_len;
             auto const data = reinterpret_cast<unsigned char const*>(luaL_checklstring(L, 4, &data_len));

             auto& ctx = MdCtx::push(L);
             ctx = EVP_MD_CTX_new();
             if (nullptr == ctx)
             {
                 openssl_failure(L, "EVP_MD_CTX_new");
             }

             auto success = EVP_DigestVerifyInit(ctx, nullptr, md, nullptr, pkey);
             if (0 >= success)
             {
                 MdCtx::reset(ctx);
                 openssl_failure(L, "EVP_DigestVerifyInit");
             }

             // Past the setup, every failure is the signature's: some key
             // types report a malformed one as an error, others as a mismatch
             success = EVP_DigestVerify(ctx, sig, sig_len, data, data_len);
             MdCtx::reset(ctx);

             // A signature that doesn't verify queues errors too
             ERR_clear_error();

             lua_pushboolean(L, 1 == success);
             return 1;
         }},

        /***
        Verify a signature made by pkey:sign, using a public key
        @function pkey:verify
        @tparam string signature
        @tparam string signed data
        @treturn boolean whether the signature verifies: false for a
        mismatch and for a malformed signature alike
        @raise openssl error when the key can't verify at all
        */
        {"verify", [](auto const L) {
             auto const pkey = check_pkey(L, 1);
             std::size_t sig_len;
             auto const sig = reinterpret_cast<unsigned char const*>(luaL_checklstring(L, 2, &sig_len));
             std::size_t data_len;
             auto const data = reinterpret_cast<unsigned char const*>(luaL_checklstring(L, 3, &data_len));

             auto& ctx = PkeyCtx::push(L);
             ctx = EVP_PKEY_CTX_new(pkey, nullptr);
             if (nullptr == ctx)
             {
                 openssl_failure(L, "EVP_PKEY_CTX_new");
             }

             auto success = EVP_PKEY_verify_init(ctx);
             if (0 >= success)
             {
                 PkeyCtx::reset(ctx);
                 openssl_failure(L, "EVP_PKEY_verify_init");
             }

             // Past the setup, every failure is the signature's, as above
             success = EVP_PKEY_verify(ctx, sig, sig_len, data, data_len);
             PkeyCtx::reset(ctx);

             // A signature that doesn't verify queues errors too
             ERR_clear_error();

             lua_pushboolean(L, 1 == success);
             return 1;
         }},

        /***
        Decrypt a message using a private key
        @function pkey:decrypt
        @tparam string ciphertext
        @tparam[opt] string format "oaep" for RSA OAEP padding; omitted or
        "" for the key type's default
        @treturn string plaintext
        @raise on any other format, or openssl error on failure
        */
        {"decrypt", [](auto const L) {
             auto const pkey = check_pkey(L, 1);
             std::size_t in_len;
             auto const in = reinterpret_cast<unsigned char const*>(luaL_checklstring(L, 2, &in_len));
             auto const format = luaL_optlstring(L, 3, "", nullptr);
             luaL_argcheck(L, 0 == strcmp("", format) || 0 == strcmp("oaep", format), 3, "unknown padding (only \"oaep\" is supported)");

             auto& ctx = PkeyCtx::push(L);
             ctx = EVP_PKEY_CTX_new(pkey, nullptr);
             if (nullptr == ctx)
             {
                 openssl_failure(L, "EVP_PKEY_CTX_new");
             }

             auto success = EVP_PKEY_decrypt_init(ctx);
             if (0 >= success)
             {
                 PkeyCtx::reset(ctx);
                 openssl_failure(L, "EVP_PKEY_decrypt_init");
             }

             if (0 == strcmp("oaep", format))
             {
                 success = EVP_PKEY_CTX_set_rsa_padding(ctx, RSA_PKCS1_OAEP_PADDING);
                 if (0 >= success)
                 {
                     PkeyCtx::reset(ctx);
                     openssl_failure(L, "EVP_PKEY_CTX_set_rsa_padding");
                 }
             }

             std::size_t out_len;
             success = EVP_PKEY_decrypt(ctx, nullptr, &out_len, in, in_len);
             if (0 >= success)
             {
                 PkeyCtx::reset(ctx);
                 openssl_failure(L, "EVP_PKEY_decrypt");
             }

             luaL_Buffer B;
             auto const out = reinterpret_cast<unsigned char*>(luaL_buffinitsize(L, &B, out_len));

             success = EVP_PKEY_decrypt(ctx, out, &out_len, in, in_len);
             PkeyCtx::reset(ctx);

             if (0 >= success)
             {
                 openssl_failure(L, "EVP_PKEY_decrypt");
             }

             luaL_pushresultsize(&B, out_len);
             return 1;
         }},

        /***
        Encrypt a message using a public key
        @function pkey:encrypt
        @tparam string plaintext
        @tparam[opt] string format "oaep" for RSA OAEP padding; omitted or
        "" for the key type's default
        @treturn string ciphertext
        @raise on any other format, or openssl error on failure
        */
        {"encrypt", [](auto const L) {
             auto const pkey = check_pkey(L, 1);
             std::size_t in_len;
             auto const in = reinterpret_cast<unsigned char const*>(luaL_checklstring(L, 2, &in_len));
             auto const format = luaL_optlstring(L, 3, "", nullptr);
             luaL_argcheck(L, 0 == strcmp("", format) || 0 == strcmp("oaep", format), 3, "unknown padding (only \"oaep\" is supported)");

             auto& ctx = PkeyCtx::push(L);
             ctx = EVP_PKEY_CTX_new(pkey, nullptr);
             if (nullptr == ctx)
             {
                 openssl_failure(L, "EVP_PKEY_CTX_new");
             }

             auto success = EVP_PKEY_encrypt_init(ctx);
             if (0 >= success)
             {
                 PkeyCtx::reset(ctx);
                 openssl_failure(L, "EVP_PKEY_encrypt_init");
             }

             if (0 == strcmp("oaep", format))
             {
                 success = EVP_PKEY_CTX_set_rsa_padding(ctx, RSA_PKCS1_OAEP_PADDING);
                 if (0 >= success)
                 {
                     PkeyCtx::reset(ctx);
                     openssl_failure(L, "EVP_PKEY_CTX_set_rsa_padding");
                 }
             }

             std::size_t out_len;
             success = EVP_PKEY_encrypt(ctx, nullptr, &out_len, in, in_len);
             if (0 >= success)
             {
                 PkeyCtx::reset(ctx);
                 openssl_failure(L, "EVP_PKEY_encrypt");
             }

             luaL_Buffer B;
             auto const out = reinterpret_cast<unsigned char*>(luaL_buffinitsize(L, &B, out_len));

             success = EVP_PKEY_encrypt(ctx, out, &out_len, in, in_len);
             PkeyCtx::reset(ctx);

             if (0 >= success)
             {
                 openssl_failure(L, "EVP_PKEY_encrypt");
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

             auto& ctx = PkeyCtx::push(L);
             ctx = EVP_PKEY_CTX_new(priv, nullptr);
             if (nullptr == ctx)
             {
                 openssl_failure(L, "EVP_PKEY_CTX_new");
             }

             auto success = EVP_PKEY_derive_init(ctx);
             if (0 >= success)
             {
                 PkeyCtx::reset(ctx);
                 openssl_failure(L, "EVP_PKEY_derive_init");
             }

             success = EVP_PKEY_derive_set_peer(ctx, pub);
             if (0 >= success)
             {
                 PkeyCtx::reset(ctx);
                 openssl_failure(L, "EVP_PKEY_derive_set_peer");
             }

             std::size_t out_len;
             success = EVP_PKEY_derive(ctx, nullptr, &out_len);
             if (0 >= success)
             {
                 PkeyCtx::reset(ctx);
                 openssl_failure(L, "EVP_PKEY_derive");
             }

             luaL_Buffer B;
             auto const out = reinterpret_cast<unsigned char*>(luaL_buffinitsize(L, &B, out_len));

             success = EVP_PKEY_derive(ctx, out, &out_len);
             PkeyCtx::reset(ctx);

             if (0 >= success)
             {
                 openssl_failure(L, "EVP_PKEY_derive");
             }

             luaL_pushresultsize(&B, out_len);
             return 1;
         }},

        /***
        Encode the private key in PEM format, encrypted when a cipher and
        password are given
        @function pkey:to_private_pem
        @tparam[opt] string cipher OpenSSL cipher name, such as "aes256"
        @tparam[opt] string password required exactly when cipher is given
        @treturn string PEM text
        @raise when only one of cipher and password is given, or openssl
        error on failure, including an unknown cipher
        */
        {"to_private_pem", [](auto const L) {
             auto const pkey = check_pkey(L, 1);
             auto const cipher_name = luaL_optlstring(L, 2, nullptr, nullptr);
             std::size_t pass_len;
             auto const pass = reinterpret_cast<unsigned char const*>(luaL_optlstring(L, 3, nullptr, &pass_len));

             luaL_argcheck(L, pass_len <= INT_MAX, 3, "too long");

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

             auto& bio = Bio::push(L);
             bio = BIO_new(BIO_s_mem());
             if (nullptr == bio)
             {
                 openssl_failure(L, "BIO_new");
             }

             if (0 == PEM_write_bio_PrivateKey(bio, pkey, cipher, pass, static_cast<int>(pass_len), nullptr, nullptr))
             {
                 openssl_failure(L, "PEM_write_bio_PrivateKey");
             }
             char* data;
             auto const len = BIO_get_mem_data(bio, &data);
             lua_pushlstring(L, data, len);
             Bio::reset(bio);
             return 1;
         }},

        /***
        Encode the public key in PEM format
        @function pkey:to_public_pem
        @treturn string PEM text
        @raise openssl error on failure
        */
        {"to_public_pem", [](auto const L) {
             auto const pkey = check_pkey(L, 1);
             auto& bio = Bio::push(L);
             bio = BIO_new(BIO_s_mem());
             if (nullptr == bio)
             {
                 openssl_failure(L, "BIO_new");
             }
             if (0 == PEM_write_bio_PUBKEY(bio, pkey))
             {
                 openssl_failure(L, "PEM_write_bio_PUBKEY");
             }
             char* data;
             auto const len = BIO_get_mem_data(bio, &data);
             lua_pushlstring(L, data, len);
             Bio::reset(bio);
             return 1;
         }},

        /***
        Export the key's parameters, such as `pub` and `priv`
        @function pkey:export
        @treturn table parameter name to value: integers as bignums,
        everything else as raw bytes in a string
        @raise openssl error on failure
        */
        {"export", [](auto const L) {
             auto const pkey = check_pkey(L, 1);

             auto& params = Params::push(L);
             if (0 == EVP_PKEY_todata(pkey, EVP_PKEY_KEYPAIR, &params))
             {
                 openssl_failure(L, "EVP_PKEY_todata");
             }

             lua_newtable(L);
             for (auto cursor = params; cursor->key; cursor++)
             {
                 switch (cursor->data_type)
                 {
                 case OSSL_PARAM_UNSIGNED_INTEGER: {
                     auto& r = push_bignum(L);
                     if (0 == OSSL_PARAM_get_BN(cursor, &r))
                     {
                         openssl_failure(L, "OSSL_PARAM_get_BN");
                     }
                     break;
                 }
                 case OSSL_PARAM_INTEGER: {
                     // OSSL_PARAM_get_BN takes signed integers only from
                     // OpenSSL 3.2, and EC keys have int parameters
                     std::int64_t value;
                     if (0 != OSSL_PARAM_get_int64(cursor, &value))
                     {
                         push_int64(L, value);
                     }
                     else
                     {
                         auto& r = push_bignum(L);
                         if (0 == OSSL_PARAM_get_BN(cursor, &r))
                         {
                             openssl_failure(L, "OSSL_PARAM_get_BN");
                         }
                     }
                     break;
                 }
                 default:
                     lua_pushlstring(L, static_cast<char const*>(cursor->data), cursor->data_size);
                     break;
                 }
                 lua_setfield(L, -2, cursor->key);
             }
             Params::reset(params);
             return 1;
         }},

        /***
        Set one of the key's settable parameters, such as "point-format"
        @function pkey:set_param
        @tparam string name parameter name
        @tparam string|integer value a string for string parameters, an
        integer in C int range for integer ones
        @raise on an unknown parameter or unsupported parameter type, or
        openssl error on failure
        */
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
                 return luaL_error(L, "type not supported %d", param->data_type);
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
                 luaL_argcheck(L, INT_MIN <= n && n <= INT_MAX, 3, "out of range");
                 auto const success = EVP_PKEY_set_int_param(pkey, name, static_cast<int>(n));
                 if (not success)
                 {
                     openssl_failure(L, "EVP_PKEY_set_int_param");
                 }
                 return 0;
             }
             }
         }},

        {}
    };

} // namespace

auto push_evp_pkey(lua_State* const L) -> EVP_PKEY*&
{
    auto& pkey = *static_cast<EVP_PKEY**>(lua_newuserdatauv(L, sizeof(EVP_PKEY*), 0));
    pkey = nullptr;
    if (luaL_newmetatable(L, pkey_name))
    {
        setfuncs(L, PkeyMT);

        luaL_newlibtable(L, PkeyMethods);
        setfuncs(L, PkeyMethods);
        lua_setfield(L, -2, "__index");
    }
    lua_setmetatable(L, -2);
    return pkey;
}

auto l_read_raw(lua_State* const L) -> int
{
    auto const type = luaL_checkinteger(L, 1);
    luaL_argcheck(L, INT_MIN <= type && type <= INT_MAX, 1, "out of range");
    auto const priv = lua_toboolean(L, 2);
    std::size_t raw_len;
    auto const raw = reinterpret_cast<unsigned char const*>(luaL_checklstring(L, 3, &raw_len));

    auto& pkey = push_evp_pkey(L);
    pkey = (priv ? EVP_PKEY_new_raw_private_key : EVP_PKEY_new_raw_public_key)(static_cast<int>(type), nullptr, raw, raw_len);
    if (nullptr == pkey)
    {
        openssl_failure(L, priv ? "EVP_PKEY_new_raw_private_key" : "EVP_PKEY_new_raw_public_key");
    }
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

    luaL_argcheck(L, key_len <= INT_MAX, 1, "too long");

    auto& pkey = push_evp_pkey(L);
    auto& bio = Bio::push(L);
    bio = BIO_new_mem_buf(key, static_cast<int>(key_len));
    if (nullptr == bio)
    {
        openssl_failure(L, "BIO_new_mem_buf");
    }

    using Invoker = Invoke<decltype(cb)>;
    pkey = (priv ? PEM_read_bio_PrivateKey : PEM_read_bio_PUBKEY)(bio, nullptr, Invoker::invoke, Invoker::prep(cb));
    Bio::reset(bio);

    if (nullptr == pkey)
    {
        openssl_failure(L, priv ? "PEM_read_bio_PrivateKey" : "PEM_read_bio_PUBKEY");
    }

    lua_pop(L, 1); // the empty BIO box
    return 1;
}

auto l_gen_pkey(lua_State* const L) -> int
{
    auto const type = luaL_checkstring(L, 1);

    if (0 == strcmp("RSA", type))
    {
        auto const bits = luaL_checkinteger(L, 2);
        luaL_argcheck(L, 0 < bits && bits <= INT_MAX, 2, "out of range");
        auto& pkey = push_evp_pkey(L);
        pkey = EVP_PKEY_Q_keygen(nullptr, nullptr, type, static_cast<std::size_t>(bits));
    }
    else if (0 == strcmp("EC", type))
    {
        auto const curve = luaL_checkstring(L, 2);
        auto& pkey = push_evp_pkey(L);
        pkey = EVP_PKEY_Q_keygen(nullptr, nullptr, type, curve);
    }
    else if (0 == strcmp("X25519", type) || 0 == strcmp("X448", type) || 0 == strcmp("ED25519", type) || 0 == strcmp("ED448", type) || 0 == strcmp("SM2", type))
    {
        auto& pkey = push_evp_pkey(L);
        pkey = EVP_PKEY_Q_keygen(nullptr, nullptr, type);
    }
    else
    {
        return luaL_error(L, "unknown key type '%s'", type);
    }

    if (nullptr == test_pkey(L, -1))
    {
        openssl_failure(L, "EVP_PKEY_Q_keygen");
    }
    return 1;
}

auto l_pkey_from_store(lua_State* const L) -> int
{
    auto const key_name = luaL_checkstring(L, 1);
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
    auto& pkey = push_evp_pkey(L);

    using Invoker = Invoke<decltype(cb)>;
    auto const ui_method = UI_UTIL_wrap_read_pem_callback(Invoker::invoke, 0);
    if (nullptr == ui_method)
    {
        openssl_failure(L, "UI_UTIL_wrap_read_pem_callback");
    }
    auto const store = OSSL_STORE_open(key_name, ui_method, Invoker::prep(cb), nullptr, nullptr);
    if (nullptr == store)
    {
        UI_destroy_method(ui_method);
        openssl_failure(L, "OSSL_STORE_open");
    }

    // A null from OSSL_STORE_load can be an item that didn't decode, with
    // more to follow, so the loop runs until end of file
    while (nullptr == pkey && not OSSL_STORE_eof(store))
    {
        auto const info = OSSL_STORE_load(store);
        if (nullptr == info)
        {
            continue;
        }
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
    }

    OSSL_STORE_close(store);
    UI_destroy_method(ui_method);

    if (nullptr == pkey)
    {
        // A wrong password or an undecodable file leaves its reason queued
        lua_pushfstring(L, "no %s key found in '%s'", priv ? "private" : "public", key_name);
        openssl_failure_message(L, lua_tostring(L, -1));
    }

    // Items skipped on the way to the key leave their errors queued
    ERR_clear_error();
    return 1;
}

} // namespace myopenssl
