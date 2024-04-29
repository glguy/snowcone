#include "x509.hpp"
#include "digest.hpp"
#include "errors.hpp"
#include "pkey.hpp"

extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

#include <openssl/asn1.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

#include <cstddef>
#include <cstdlib>
#include <initializer_list>

namespace myopenssl {

namespace {

auto l_gc(lua_State* const L) -> int
{
    // don't use check_x509 to allow for nullptr case
    X509 ** const x509Ptr = static_cast<X509**>(luaL_checkudata(L, 1, "x509"));
    X509_free(*x509Ptr);
    *x509Ptr = nullptr;
    return 0;
}

auto check_x509(lua_State* const L, int const arg) -> X509*
{
    auto const x509 = *static_cast<X509**>(luaL_checkudata(L, arg, "x509"));
    luaL_argcheck(L, nullptr != x509, arg, "x509 already closed");
    return x509;
}

luaL_Reg const X509MT[] {
    {"__gc", l_gc},
    {"__close", l_gc},
    {}
};

auto to_ASN1_TIME(lua_State* const L, char const* const str) -> ASN1_TIME*
{
    auto const asnTime = ASN1_TIME_new();
    if (0 == ASN1_TIME_set_string_X509(asnTime, str))
    {
        ASN1_TIME_free(asnTime);
        openssl_failure(L, "ASN1_TIME_set_string_X509");
    }
    return asnTime;
}

auto to_X509_NAME(lua_State* const L, int const arg) -> X509_NAME*
{
    auto const name = X509_NAME_new();
    lua_pushnil(L); // first key
    while (0 != lua_next(L, arg))
    {
        auto const field = lua_tostring(L, -2);
        std::size_t len;
        auto const value = lua_tolstring(L, -1, &len);

        if (nullptr == field || nullptr == value)
        {
            X509_NAME_free(name);
            luaL_error(L, "bad name");
        }

        X509_NAME_add_entry_by_txt(name, field, MBSTRING_UTF8, reinterpret_cast<unsigned char const*>(value), len, -1, 0);
        lua_pop(L, 1); // remove value but leave key on stack
    }
    lua_pop(L, 1); // pop last key

    return name;
}

enum class KeyUsage
{
    DigitalSignature = 0,
    ContentCommitment = 1,
    KeyEncipherment = 2,
    DataEncipherment = 3,
    KeyAgreement = 4,
    KeyCertSign = 5,
    CRLSign = 6,
    EncipherOnly = 7,
    DecipherOnly = 8,
};

auto add_key_usage(
    lua_State* const L,
    X509* const x509,
    std::initializer_list<KeyUsage> const flags
) -> void
{
    auto const usage = ASN1_BIT_STRING_new();
    if (nullptr == usage)
    {
        openssl_failure(L, "ASN1_BIT_STRING_new");
    }

    for (auto const i : flags)
    {
        if (1 != ASN1_BIT_STRING_set_bit(usage, static_cast<int>(i), 1))
        {
            ASN1_BIT_STRING_free(usage);
            openssl_failure(L, "ASN1_BIT_STRING_set_bit");
        }
    }

    // key usage MUST be critical
    auto const result = X509_add1_ext_i2d(x509, NID_key_usage, usage, 1, X509V3_ADD_DEFAULT);
    ASN1_BIT_STRING_free(usage);

    // N.B. this can return 0 and -1 on failure
    if (1 != result)
    {
        openssl_failure(L, "X509_add1_ext_i2d");
    }
}

// Allow client authentication extended key usage
auto add_extended_key_usage(lua_State* const L, X509* const x509, int nid) -> void
{
    auto const usage = EXTENDED_KEY_USAGE_new();
    if (nullptr == usage)
    {
        openssl_failure(L, "EXTENDED_KEY_USAGE_new");
    }

    if (1 != sk_ASN1_OBJECT_push(usage, OBJ_nid2obj(nid)))
    {
        EXTENDED_KEY_USAGE_free(usage);
        openssl_failure(L, "sk_ASN1_OBJECT_push");
    }

    auto const result = X509_add1_ext_i2d(x509, NID_ext_key_usage, usage, 1, X509V3_ADD_DEFAULT);
    EXTENDED_KEY_USAGE_free(usage);

    if (1 != result)
    {
        openssl_failure(L, "X509_add1_ext_i2d");
    }
}

/***
@type x509
*/

luaL_Reg const X509Methods[] {
    {"set_version", [](auto const L) {
        auto const x509 = check_x509(L, 1);
        auto const version = luaL_checkinteger(L, 2);
        if (0 == X509_set_version(x509, version)) {
            openssl_failure(L, "X509_set_version");
        }
        return 0;
    }},
    {"set_pubkey", [](auto const L) {
        auto const x509 = check_x509(L, 1);
        auto const pkey = check_pkey(L, 2);

        if (0 == X509_set_pubkey(x509, pkey))
        {
            openssl_failure(L, "X509_set_pubkey");
        }
        return 0;
    }},
    {"sign", [](auto const L) {
        auto const x509 = check_x509(L, 1);
        auto const pkey = check_pkey(L, 2);

        EVP_MD const* md {};
        if (not lua_isnoneornil(L, 3))
        {
            md = check_digest(L, 3);
        }

        if (0 == X509_sign(x509, pkey, md))
        {
            openssl_failure(L, "X509_sign");
        }
        return 0;
    }},
    {"fingerprint", [](auto const L) {
        auto const x509 = check_x509(L, 1);
        auto const md = check_digest(L, 2);

        unsigned int len = EVP_MD_get_size(md);
        luaL_Buffer B;
        unsigned char * bytes = reinterpret_cast<unsigned char*>(luaL_buffinitsize(L, &B, len));

        if (0 == X509_digest(x509, md, bytes, &len))
        {
            openssl_failure(L, "X509_digest");
        }
        luaL_pushresultsize(&B, len);
        return 1;
    }},
    {"export", [](auto const L)
    {
        auto const x509 = check_x509(L, 1);
        auto const bio = BIO_new(BIO_s_mem());
        if (nullptr == bio)
        {
            openssl_failure(L, "BIO_new");
        }
        if (0 == PEM_write_bio_X509(bio, x509))
        {
            BIO_free_all(bio);
            openssl_failure(L, "PEM_write_bio_X509");
        }
        char* data;
        auto const len = BIO_get_mem_data(bio, &data);
        lua_pushlstring(L, data, len);
        BIO_free_all(bio);
        return 1;
    }},
    {"set_serialNumber", [](auto const L) {
        auto const x509 = check_x509(L, 1);
        auto const number = luaL_checkinteger(L, 2);

        auto const asnNumber = ASN1_INTEGER_new();
        ASN1_INTEGER_set_int64(asnNumber, number);
        auto const result = X509_set_serialNumber(x509, asnNumber);
        ASN1_INTEGER_free(asnNumber);

        if (0 == result)
        {
            openssl_failure(L, "X509_set_serialNumber");
        }
        return 0;
    }},
    {"set_notBefore", [](auto const L) {
        auto const x509 = check_x509(L, 1);
        auto const timeStr = luaL_checkstring(L, 2);

        auto const ansTime = to_ASN1_TIME(L, timeStr);
        auto const result = X509_set1_notBefore(x509, ansTime);
        ASN1_TIME_free(ansTime);

        if (0 == result)
        {
            openssl_failure(L, "X509_set1_notBefore");
        }
        return 0;
    }},
    {"set_notAfter", [](auto const L) {
        auto const x509 = check_x509(L, 1);
        auto const timeStr = luaL_checkstring(L, 2);

        auto const ansTime = to_ASN1_TIME(L, timeStr);
        auto const result = X509_set1_notAfter(x509, ansTime);
        ASN1_TIME_free(ansTime);

        if (0 == result)
        {
            openssl_failure(L, "X509_set1_notAfter");
        }
        return 0;
    }},
    {"set_issuerName", [](auto const L) {
        auto const x509 = check_x509(L, 1);
        luaL_checktype(L, 2, LUA_TTABLE);

        auto const name = to_X509_NAME(L, 2);
        auto const result = X509_set_issuer_name(x509, name);
        X509_NAME_free(name);

        if (0 == result)
        {
            openssl_failure(L, "X509_set_issuer_name");
        }
        return 0;
    }},
    {"set_subjectName", [](auto const L) {
        auto const x509 = check_x509(L, 1);
        luaL_checktype(L, 2, LUA_TTABLE);

        auto const name = to_X509_NAME(L, 2);
        auto const result = X509_set_subject_name(x509, name);
        X509_NAME_free(name);

        if (0 == result) {
            openssl_failure(L, "X509_set_subject_name");
        }
        return 0;
    }},
    {"add_caConstraint", [](auto const L) {
        auto const x509 = check_x509(L, 1);
        auto const cA = lua_toboolean(L, 2);

        auto const bs = BASIC_CONSTRAINTS_new();
        if (nullptr == bs)
        {
            openssl_failure(L, "BASIC_CONSTRAINTS_new");
        }
        bs->ca = cA;

        auto const result = X509_add1_ext_i2d(x509, NID_basic_constraints, bs, 1, X509_ADD_FLAG_DEFAULT);
        BASIC_CONSTRAINTS_free(bs);

        if (1 != result)
        {
            openssl_failure(L, "X509_add1_ext_i2d");
        }
        return 0;
    }
    },
    {"add_clientUsageConstraint", [](auto const L) {
        auto const x509 = check_x509(L, 1);
        add_key_usage(L, x509, {KeyUsage::DigitalSignature, KeyUsage::KeyAgreement});
        add_extended_key_usage(L, x509, NID_client_auth);
        return 0;
    }},
    {"add_serverUsageConstraint", [](auto const L) {
        auto const x509 = check_x509(L, 1);
        add_key_usage(L, x509, {KeyUsage::DigitalSignature, KeyUsage::KeyEncipherment, KeyUsage::KeyAgreement});
        add_extended_key_usage(L, x509, NID_server_auth);
        return 0;
    }},
    {"add_subjectKeyIdentifier", [](auto const L) {
        auto const x509 = check_x509(L, 1);
        std::size_t len;
        auto const bytes = luaL_checklstring(L, 2, &len);

        auto const key_identifier = ASN1_OCTET_STRING_new();
        if (nullptr == key_identifier)
        {
            openssl_failure(L, "ASN1_OCTET_STRING_new");
        }

        if (0 == ASN1_OCTET_STRING_set(key_identifier, reinterpret_cast<unsigned char const*>(bytes), len))
        {
            ASN1_OCTET_STRING_free(key_identifier);
            openssl_failure(L, "ASN1_OCTET_STRING_set");
        }

        auto const result = X509_add1_ext_i2d(x509, NID_subject_key_identifier, key_identifier, 0, X509_ADD_FLAG_DEFAULT);
        ASN1_OCTET_STRING_free(key_identifier);

        if (1 != result)
        {
            openssl_failure(L, "X509_add1_ext_i2d");
        }
        return 0;
    }},
    {"add_authorityKeyIdentifier", [](auto const L) {
        auto const x509 = check_x509(L, 1);
        std::size_t len;
        auto const bytes = luaL_checklstring(L, 2, &len);

        AUTHORITY_KEYID auth{.keyid = ASN1_OCTET_STRING_new()};
        if (nullptr == auth.keyid)
        {
            openssl_failure(L, "ASN1_OCTET_STRING_new");
        }

        if (0 == ASN1_OCTET_STRING_set(auth.keyid, reinterpret_cast<unsigned char const*>(bytes), len))
        {
            ASN1_OCTET_STRING_free(auth.keyid);
            openssl_failure(L, "ASN1_OCTET_STRING_set");
        }

        auto const result = X509_add1_ext_i2d(x509, NID_authority_key_identifier, &auth, 0, X509_ADD_FLAG_DEFAULT);
        ASN1_OCTET_STRING_free(auth.keyid);

        if (1 != result)
        {
            openssl_failure(L, "X509_add1_ext_i2d");
        }
        return 0;
    }},
    {}
};

auto push_x509(lua_State * const L, X509 * x509) -> void
{
    *static_cast<X509**>(lua_newuserdatauv(L, sizeof x509, 0)) = x509;
    if (luaL_newmetatable(L, "x509"))
    {
        luaL_setfuncs(L, X509MT, 0);

        luaL_newlibtable(L, X509Methods);
        luaL_setfuncs(L, X509Methods, 0);
        lua_setfield(L, -2, "__index");
    }
    lua_setmetatable(L, -2);
}

} // namespace

auto l_new_x509(lua_State* const L) -> int
{
    if (auto const x509 = X509_new())
    {
        push_x509(L, x509);
        return 1;
    }
    else
    {
        openssl_failure(L, "X509_new");
    }
}

} // namespace myopenssl
