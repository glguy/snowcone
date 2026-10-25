#include "x509.hpp"
#include "digest.hpp"
#include "errors.hpp"
#include "invoke.hpp"
#include "pkey.hpp"

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <openssl/asn1.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

#include <climits>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <utility>

namespace myopenssl {

static char const x509_name[] = "X509*";

auto check_x509(lua_State* const L, int const arg) -> X509*
{
    auto const x509 = *static_cast<X509**>(luaL_checkudata(L, arg, x509_name));
    luaL_argcheck(L, nullptr != x509, arg, "x509 already closed");
    return x509;
}

auto test_x509(lua_State* const L, int const arg) -> X509*
{
    auto const x509 = static_cast<X509**>(luaL_testudata(L, arg, x509_name));
    return x509 ? *x509 : nullptr;
}

namespace {

    auto l_gc(lua_State* const L) -> int
    {
        // don't use check_x509 to allow for nullptr case
        X509** const x509Ptr = static_cast<X509**>(luaL_checkudata(L, 1, x509_name));
        X509_free(*x509Ptr);
        *x509Ptr = nullptr;
        return 0;
    }

    luaL_Reg const X509MT[]{
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

    /// Field and value of name entry i (1-based) in the list at arg, or
    /// nulls if the entry isn't a pair of strings. Uses raw access only, so
    /// it never raises; pushes nothing.
    auto name_entry(lua_State* const L, int const arg, lua_Integer const i, std::size_t& value_len)
        -> std::pair<char const*, char const*>
    {
        auto const fail = std::pair<char const*, char const*>{};
        if (LUA_TTABLE != lua_rawgeti(L, arg, i))
        {
            lua_pop(L, 1);
            return fail;
        }
        std::size_t field_len;
        auto const field = LUA_TSTRING == lua_rawgeti(L, -1, 1) ? lua_tolstring(L, -1, &field_len) : nullptr;
        auto const value = LUA_TSTRING == lua_rawgeti(L, -2, 2) ? lua_tolstring(L, -1, &value_len) : nullptr;
        lua_pop(L, 3); // the strings stay alive in the list
        if (nullptr == field || nullptr == value || std::strlen(field) != field_len || value_len > INT_MAX)
        {
            return fail;
        }
        return {field, value};
    }

    /// Builds a name from a list of {field, value} pairs, in list order.
    /// The field is a short name (CN), long name (commonName) or dotted OID.
    auto to_X509_NAME(lua_State* const L, int const arg) -> X509_NAME*
    {
        luaL_checktype(L, arg, LUA_TTABLE);
        auto const n = static_cast<lua_Integer>(lua_rawlen(L, arg));

        // Validate everything before allocating, so a Lua error leaks nothing
        lua_Integer keys = 0;
        lua_pushnil(L);
        while (0 != lua_next(L, arg))
        {
            lua_pop(L, 1);
            keys++;
        }
        if (keys != n)
        {
            luaL_argerror(L, arg, "name must be a list of {field, value} pairs");
        }
        for (lua_Integer i = 1; i <= n; i++)
        {
            std::size_t len;
            if (nullptr == name_entry(L, arg, i, len).first)
            {
                luaL_error(L, "bad argument #%d (name entry %d must be {field, value} strings)", arg, static_cast<int>(i));
            }
        }

        auto const name = X509_NAME_new();
        if (nullptr == name)
        {
            openssl_failure(L, "X509_NAME_new");
        }
        for (lua_Integer i = 1; i <= n; i++)
        {
            std::size_t len;
            auto const [field, value] = name_entry(L, arg, i, len);
            if (0 == X509_NAME_add_entry_by_txt(name, field, MBSTRING_UTF8, reinterpret_cast<unsigned char const*>(value), static_cast<int>(len), -1, 0))
            {
                X509_NAME_free(name);
                openssl_failure(L, "X509_NAME_add_entry_by_txt");
            }
        }
        return name;
    }

    /// Pushes the field of a name entry: its short name, or the dotted OID
    /// when OpenSSL has no name for it
    auto push_field(lua_State* const L, ASN1_OBJECT const* const object) -> void
    {
        auto const nid = OBJ_obj2nid(object);
        if (NID_undef != nid)
        {
            if (auto const sn = OBJ_nid2sn(nid))
            {
                lua_pushstring(L, sn);
                return;
            }
        }

        auto const len = OBJ_obj2txt(nullptr, 0, object, 1);
        if (len <= 0)
        {
            openssl_failure(L, "OBJ_obj2txt");
        }
        luaL_Buffer B;
        auto const buf = luaL_buffinitsize(L, &B, len + 1);
        OBJ_obj2txt(buf, len + 1, object, 1);
        luaL_pushresultsize(&B, len);
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

    luaL_Reg const X509Methods[]{
        {"set_version", [](auto const L) {
             auto const x509 = check_x509(L, 1);
             auto const version = luaL_checkinteger(L, 2);
             if (0 == X509_set_version(x509, version))
             {
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
        {"get_pubkey", [](auto const L) {
             auto const x509 = check_x509(L, 1);
             auto const pkey = X509_get_pubkey(x509);
             if (nullptr == pkey)
             {
                 openssl_failure(L, "X509_get_pubkey");
             }
             push_evp_pkey(L, pkey);
             return 1;
         }},
        {"sign", [](auto const L) {
             auto const x509 = check_x509(L, 1);
             auto const pkey = check_pkey(L, 2);
             EVP_MD const* md = luaL_opt(L, check_digest, 3, nullptr);

             if (0 == X509_sign(x509, pkey, md))
             {
                 openssl_failure(L, "X509_sign");
             }
             return 0;
         }},
        {"fingerprint", [](auto const L) {
             auto const x509 = check_x509(L, 1);
             auto const md = check_digest(L, 2);

             unsigned int len;
             luaL_Buffer B;
             unsigned char* bytes = reinterpret_cast<unsigned char*>(luaL_buffinitsize(L, &B, EVP_MAX_MD_SIZE));

             if (0 == X509_digest(x509, md, bytes, &len))
             {
                 openssl_failure(L, "X509_digest");
             }
             luaL_pushresultsize(&B, len);
             return 1;
         }},
        {"export", [](auto const L) {
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
        /***
        Set the issuer name
        @function x509:set_issuerName
        @tparam {{string,string},...} name list of {field, value} pairs in
        order; a field is a short name (CN), long name (commonName) or dotted OID
        @raise on a malformed list or an unknown field
        */
        {"set_issuerName", [](auto const L) {
             auto const x509 = check_x509(L, 1);

             auto const name = to_X509_NAME(L, 2);
             auto const result = X509_set_issuer_name(x509, name);
             X509_NAME_free(name);

             if (0 == result)
             {
                 openssl_failure(L, "X509_set_issuer_name");
             }
             return 0;
         }},
        /***
        Set the subject name
        @function x509:set_subjectName
        @tparam {{string,string},...} name list of {field, value} pairs in
        order; a field is a short name (CN), long name (commonName) or dotted OID
        @raise on a malformed list or an unknown field
        */
        {"set_subjectName", [](auto const L) {
             auto const x509 = check_x509(L, 1);

             auto const name = to_X509_NAME(L, 2);
             auto const result = X509_set_subject_name(x509, name);
             X509_NAME_free(name);

             if (0 == result)
             {
                 openssl_failure(L, "X509_set_subject_name");
             }
             return 0;
         }},
        /***
        Get the subject name
        @function x509:get_subjectName
        @treturn {{string,string},...} list of {field, value} pairs in
        certificate order; a field is its short name, or a dotted OID when
        OpenSSL has no name for it
        */
        {"get_subjectName", [](auto const L) {
             auto const x509 = check_x509(L, 1);

             // internal pointer
             auto const name = X509_get_subject_name(x509);
             if (nullptr == name)
             {
                 openssl_failure(L, "X509_get_subject_name");
             }

             auto const entryCount = X509_NAME_entry_count(name);
             lua_createtable(L, entryCount, 0);
             for (int i = 0; i < entryCount; ++i)
             {
                 auto const entry = X509_NAME_get_entry(name, i);
                 auto const object = X509_NAME_ENTRY_get_object(entry);
                 auto const data = X509_NAME_ENTRY_get_data(entry);

                 unsigned char* utf8;
                 auto const length = ASN1_STRING_to_UTF8(&utf8, data);
                 if (length < 0)
                 {
                     openssl_failure(L, "ASN1_STRING_to_UTF8");
                 }

                 // {field, value}, in certificate order
                 lua_createtable(L, 2, 0);
                 lua_pushlstring(L, reinterpret_cast<char const*>(utf8), length);
                 OPENSSL_free(utf8);
                 lua_rawseti(L, -2, 2);
                 push_field(L, object);
                 lua_rawseti(L, -2, 1);
                 lua_rawseti(L, -2, i + 1);
             }

             return 1;
         }},
        {"add_caConstraint", [](auto const L) {
             auto const x509 = check_x509(L, 1);
             auto const cA = lua_toboolean(L, 2);

             BASIC_CONSTRAINTS bs{.ca = cA};
             auto const result = X509_add1_ext_i2d(x509, NID_basic_constraints, &bs, 1, X509_ADD_FLAG_DEFAULT);

             if (1 != result)
             {
                 openssl_failure(L, "X509_add1_ext_i2d");
             }
             return 0;
         }},
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

    auto push_x509(lua_State* const L, X509* x509) -> void
    {
        *static_cast<X509**>(lua_newuserdatauv(L, sizeof x509, 0)) = x509;
        if (luaL_newmetatable(L, x509_name))
        {
            setfuncs(L, X509MT);

            luaL_newlibtable(L, X509Methods);
            setfuncs(L, X509Methods);
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

auto l_read_x509(lua_State* const L) -> int
{
    std::size_t key_len;
    auto const key = luaL_checklstring(L, 1, &key_len);
    std::size_t pass_len;
    auto const pass = luaL_optlstring(L, 2, "", &pass_len);

    auto const cb = [pass, pass_len](char* buf, int size, int) -> int {
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
    auto const x509 = PEM_read_bio_X509(bio, nullptr, Invoker::invoke, Invoker::prep(cb));

    BIO_free_all(bio);

    if (nullptr == x509)
    {
        openssl_failure(L, "PEM_read_bio_X509");
    }

    push_x509(L, x509);
    return 1;
}

} // namespace myopenssl
