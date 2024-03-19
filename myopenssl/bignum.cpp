#include "bignum.hpp"
#include "errors.hpp"

extern "C"
{
#include <lua.h>
#include <lauxlib.h>
}

#include <cstring>
#include <memory>

namespace myopenssl {

namespace {

constexpr char const* bignum_name = "bignum";

struct BN_CTX_Deleter
{
    auto operator()(BN_CTX* ctx) const -> void {
        BN_CTX_free(ctx);
    }
};

thread_local std::unique_ptr<BN_CTX, BN_CTX_Deleter> bn_ctx{BN_CTX_new()};

auto checkbignum(lua_State* const L, int idx) -> BIGNUM*&
{
    auto& bn = *reinterpret_cast<BIGNUM**>(luaL_checkudata(L, idx, bignum_name));
    luaL_argcheck(L, nullptr != bn, 1, "panic: bignum not allocated");
    return bn;       
}

template <int X, bool B>
auto compare_bignum(lua_State* const L) -> int
{
    auto const a = checkbignum(L, 1);
    auto const b = checkbignum(L, 2);
    auto const r = BN_cmp(a, b);
    lua_pushboolean(L, (r == X) == B);
    return 1;
}

luaL_Reg const MT[] = {
    {"__tostring", [](auto const L) {
        auto const bn = checkbignum(L, 1);
        auto const str = BN_bn2dec(bn);
        lua_pushstring(L, str);
        OPENSSL_free(str);
        return 1;
    }},
    {"__gc", [](auto const L) {
        auto& bn = checkbignum(L, 1);
        BN_free(bn);
        bn = nullptr;
        return 0;
    }},
    {"__add", [](auto const L) {
        auto const a = checkbignum(L, 1);
        auto const b = checkbignum(L, 2);
        auto& r = push_bignum(L);

        if (1 == BN_add(r, a, b))
        {
            return 1;
        }
        else
        {
            return luaL_error(L, "bignum failure");
        }
    }},
    {"__sub", [](auto const L) {
        auto const a = checkbignum(L, 1);
        auto const b = checkbignum(L, 2);
        auto& r = push_bignum(L);

        if (1 == BN_sub(r, a, b))
        {
            return 1;
        }
        else
        {
            return luaL_error(L, "bignum failure");
        }
    }},
    {"__mul", [](auto const L) {
        auto const a = checkbignum(L, 1);
        auto const b = checkbignum(L, 2);
        auto& r = push_bignum(L);

        if (1 == BN_mul(r, a, b, bn_ctx.get()))
        {
            return 1;
        }
        else
        {
            return luaL_error(L, "bignum failure");
        }
    }},
    {"__idiv", [](auto const L){
        auto const a = checkbignum(L, 1);
        auto const b = checkbignum(L, 2);
        auto& r = push_bignum(L);

        if (1 == BN_div(r, nullptr, a, b, bn_ctx.get()))
        {
            return 1;
        }
        else
        {
            return luaL_error(L, "bignum failure");
        }
    }},
    {"__mod", [](auto const L){
        auto const a = checkbignum(L, 1);
        auto const b = checkbignum(L, 2);
        auto& r = push_bignum(L);

        if (1 == BN_div(nullptr, r, a, b, bn_ctx.get()))
        {
            return 1;
        }
        else
        {
            return luaL_error(L, "bignum failure");
        }
    }},
    {"__pow", [](auto const L){
        auto const a = checkbignum(L, 1);
        auto const p = checkbignum(L, 2);
        auto& r = push_bignum(L);

        if (1 == BN_exp(r, a, p, bn_ctx.get()))
        {
            return 1;
        }
        else
        {
            return luaL_error(L, "bignum failure");
        }
    }},
    {"__unm", [](auto const L){
        auto const a = checkbignum(L, 1);
        auto& r = push_bignum(L);
        r = BN_dup(a);
        BN_set_negative(r, !BN_is_negative(r));
        return 1;
    }},
    {"__shl", [](auto const L){
        auto const a = checkbignum(L, 1);
        auto const n = luaL_checkinteger(L, 2);
        auto& r = push_bignum(L);
        if (1 == BN_lshift(r, a, n)) {
            return 1;
        } else {
            return luaL_error(L, "bignum failure"); 
        }
    }},
    {"__shr", [](auto const L){
        auto const a = checkbignum(L, 1);
        auto const n = luaL_checkinteger(L, 2);
        auto& r = push_bignum(L);
        if (1 == BN_rshift(r, a, n)) {
            return 1;
        } else {
            return luaL_error(L, "bignum failure"); 
        }
    }},
    {"__eq", compare_bignum<0, true>},
    {"__lt", compare_bignum<-1, true>},
    {"__gt", compare_bignum<1, true>},
    {"__le", compare_bignum<1, false>},
    {}
};

luaL_Reg const Methods[] = {
    {"div_mod", [](auto const L) {
        auto const a = checkbignum(L, 1);
        auto const b = checkbignum(L, 2);
        auto& d = push_bignum(L);
        auto& m = push_bignum(L);

        if (1 == BN_div(d, m, a, b, bn_ctx.get()))
        {
            return 2;
        }
        else
        {
            return luaL_error(L, "bignum failure");
        }
    }},
    {"mod_exp", [](auto const L) {
        auto const a = checkbignum(L, 1);
        auto const p = checkbignum(L, 2);
        auto const m = checkbignum(L, 3);
        auto& r = push_bignum(L);

        if (1 == BN_mod_exp(r, a, p, m, bn_ctx.get())) {
            return 1;
        } else {
            return luaL_error(L, "bignum failure"); 
        }
    }},
    {}
};

} // namespace

auto push_bignum(lua_State* const L) -> BIGNUM*&
{
    auto const ptr = reinterpret_cast<BIGNUM**>(lua_newuserdatauv(L, sizeof (BIGNUM*), 0));
    *ptr = nullptr;

    // Configure userdata's metatable
    if (luaL_newmetatable(L, bignum_name))
    {
        luaL_setfuncs(L, MT, 0);
        luaL_newlibtable(L, Methods);
        luaL_setfuncs(L, Methods, 0);
        lua_setfield(L, -2, "__index");
    }
    lua_setmetatable(L, -2);
    return *ptr;
}

auto l_bignum(lua_State* const L) -> int
{
    // pass existing bignums through
    auto const type_name = luaL_typename(L, 1);
    if (nullptr != type_name && 0 == strcmp(bignum_name, type_name)) {
        lua_settop(L, 1);
        return 1;
    }

    auto const str = luaL_tolstring(L, 1, nullptr);
    auto& r = push_bignum(L);
    if (1 == BN_dec2bn(&r, str))
    {
        return 1;
    }
    else
    {
        return luaL_error(L, "bad bignum string");
    }
}

} // namespace myopenssl
