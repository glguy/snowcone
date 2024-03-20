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

template <typename> struct WrapArg;

// Populate the parameter with a new bignum output argument
// pushing the result value onto the Lua stack
template <> struct WrapArg<BIGNUM*> {
    BIGNUM* operator()(lua_State * const L, int&, int& r) {
        r++;
        return push_bignum(L, BN_new());
    }
};

// Populate the parameter with a bignum argument
template <> struct WrapArg<BIGNUM const*> {
    BIGNUM const* operator()(lua_State * const L, int& a, int&) {
        return checkbignum(L, ++a);
    }
};

// Populate the parameter with an int argument
template <> struct WrapArg<int> {
    int operator()(lua_State * const L, int& a, int&) {
        return luaL_checkinteger(L, ++a);
    }
};

template <> struct WrapArg<BN_CTX*> {
    BN_CTX* operator()(lua_State * const L, int&, int&) {
        return bn_ctx.get();
    }
};

template <typename Func, Func func>
struct Wrap_ {};

template <typename... Args, int (*op)(Args...)>
struct Wrap_<int (*)(Args...), op> {
    static int wrap(lua_State* const L) {
        int a = 0;
        int r = 0;
        int result = op(WrapArg<Args>{}(L, a, r)...);
        if (1 == result) {
            return r;
        } else {
            openssl_failure(L, "bignum failure");
        }
    }
};

template <auto T>
using Wrap = Wrap_<decltype(T), T>;

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
    {"__add", Wrap<BN_add>::wrap},
    {"__sub", Wrap<BN_sub>::wrap},
    {"__mul", Wrap<BN_mul>::wrap},
    {"__idiv", [](auto const L){
        auto const a = checkbignum(L, 1);
        auto const b = checkbignum(L, 2);
        auto const r = push_bignum(L, BN_new());

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
        auto const r = push_bignum(L, BN_new());

        if (1 == BN_mod(r, a, b, bn_ctx.get()))
        {
            return 1;
        }
        else
        {
            return luaL_error(L, "bignum failure");
        }
    }},
    {"__pow", Wrap<BN_exp>::wrap},
    {"__unm", [](auto const L){
        auto const a = checkbignum(L, 1);
        auto const r = push_bignum(L, BN_dup(a));
        BN_set_negative(r, !BN_is_negative(r));
        return 1;
    }},
    {"__shl", Wrap<BN_lshift>::wrap},
    {"__shr", Wrap<BN_rshift>::wrap},
    {"__eq", compare_bignum<0, true>},
    {"__lt", compare_bignum<-1, true>},
    {"__gt", compare_bignum<1, true>},
    {"__le", compare_bignum<1, false>},
    {}
};

luaL_Reg const Methods[] = {
    {"div_mod", Wrap<BN_div>::wrap},
    {"mod_exp", Wrap<BN_mod_exp>::wrap},
    {}
};

} // namespace

auto push_bignum(lua_State* const L, BIGNUM* bn) -> BIGNUM*
{
    *reinterpret_cast<BIGNUM**>(lua_newuserdatauv(L, sizeof bn, 0)) = bn;

    // Configure userdata's metatable
    if (luaL_newmetatable(L, bignum_name))
    {
        luaL_setfuncs(L, MT, 0);
        luaL_newlibtable(L, Methods);
        luaL_setfuncs(L, Methods, 0);
        lua_setfield(L, -2, "__index");
    }
    lua_setmetatable(L, -2);
    return bn;
}

auto l_bignum(lua_State* const L) -> int
{
    // pass existing bignums through
    auto const type_name = luaL_typename(L, 1);
    if (nullptr != type_name && 0 == strcmp(bignum_name, type_name)) {
        lua_settop(L, 1);
        return 1;
    }

    std::size_t len;
    auto const str = luaL_tolstring(L, 1, &len);
    auto r = push_bignum(L, BN_new());
    if (0 != BN_dec2bn(&r, str))
    {
        return 1;
    }
    else
    {
        return luaL_error(L, "bad bignum string");
    }
}

} // namespace myopenssl
