/***
arbitrary precision integers, from myopenssl.bignum

Supports `+ - * // % ^ << >> == < <=` and unary `-` between bignums; other
operands raise an argument error. `//` and `%` truncate toward zero
(OpenSSL's BN_div and BN_mod), unlike Lua's integer operators, which floor.
Shift counts are integers from 0 to INT_MAX. tostring gives decimal.
Closing (or collecting) a bignum frees it, and later use raises
"bignum already closed".

@classmod bignum
*/

#include "bignum.hpp"
#include "errors.hpp"
#include "owned.hpp"

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <climits>
#include <functional>
#include <memory>
#include <tuple>

namespace myopenssl {

namespace {

    /// Registry name of the bignum metatable
    constexpr char const* bignum_name = "BN*";

    /// Frees a BN_CTX for unique_ptr
    struct BN_CTX_Deleter
    {
        auto operator()(BN_CTX* ctx) const -> void
        {
            BN_CTX_free(ctx);
        }
    };

    /// Scratch context shared by every operation on this thread, made on
    /// first use
    thread_local std::unique_ptr<BN_CTX, BN_CTX_Deleter> bn_ctx;

    /// This thread's scratch context. Raises an OpenSSL error if it can't
    /// be allocated.
    auto get_bn_ctx(lua_State* const L) -> BN_CTX*
    {
        if (not bn_ctx)
        {
            bn_ctx.reset(BN_CTX_new());
            if (not bn_ctx)
            {
                openssl_failure(L, "BN_CTX_new");
            }
        }
        return bn_ctx.get();
    }

    /// The open bignum at idx, or raise an argument error. Returns a
    /// reference to the userdata's slot; the userdata owns the BIGNUM.
    auto checkbignum(lua_State* const L, int idx) -> BIGNUM*&
    {
        auto& bn = *reinterpret_cast<BIGNUM**>(luaL_checkudata(L, idx, bignum_name));
        luaL_argcheck(L, nullptr != bn, idx, "bignum already closed");
        return bn;
    }

    /// Arg<T>::arg(L, a, r) produces the next OpenSSL parameter of type T:
    /// a counts Lua arguments consumed, r the results pushed.
    template <typename>
    struct Arg;

    // Populate the parameter with a new bignum output argument
    // pushing the result value onto the Lua stack
    template <>
    struct Arg<BIGNUM*>
    {
        static auto arg(lua_State* const L, int&, int& r) -> BIGNUM*
        {
            r++;
            return new_bignum(L);
        }
    };

    // Populate the parameter with a bignum argument
    template <>
    struct Arg<BIGNUM const*>
    {
        static auto arg(lua_State* const L, int& a, int&) -> BIGNUM const*
        {
            return checkbignum(L, ++a);
        }
    };

    // Populate the parameter with an int argument from 0 to INT_MAX
    template <>
    struct Arg<int>
    {
        static auto arg(lua_State* const L, int& a, int&) -> int
        {
            auto const n = luaL_checkinteger(L, ++a);
            luaL_argcheck(L, 0 <= n && n <= INT_MAX, a, "out of range");
            return static_cast<int>(n);
        }
    };

    // Populate the parameter with the shared scratch context
    template <>
    struct Arg<BN_CTX*>
    {
        static auto arg(lua_State* const L, int&, int&) -> BN_CTX*
        {
            return get_bn_ctx(L);
        }
    };

    /// Wrap<op>::wrap is a Lua function calling OpenSSL op with parameters
    /// built by Arg, in order. Returns the BIGNUM outputs it pushed, or
    /// raises an OpenSSL error unless op returns 1.
    template <auto>
    struct Wrap;

    template <typename... Args, int (*op)(Args...)>
    struct Wrap<op>
    {
        static auto wrap(lua_State* const L) -> int
        {
            int a = 0;
            int r = 0;
            // tuple initializer forces the sequencing needed
            if (1 == std::apply(op, std::tuple{Arg<Args>::arg(L, a, r)...}))
            {
                return r;
            }
            else
            {
                openssl_failure(L, "bignum operation");
            }
        }
    };

    /// Comparison metamethod: whether BN_cmp(arg 1, arg 2) == X is B
    template <int X, bool B>
    auto compare_bignum(lua_State* const L) -> int
    {
        auto const a = checkbignum(L, 1);
        auto const b = checkbignum(L, 2);
        auto const r = BN_cmp(a, b);
        lua_pushboolean(L, (r == X) == B);
        return 1;
    }

    /// __gc and __close: free the BIGNUM and mark the userdata closed.
    /// Safe to run again on a closed bignum.
    auto l_gc(lua_State* const L) -> int
    {
        // don't use checkbignum to allow for nullptr case
        auto& bn = *static_cast<BIGNUM**>(luaL_checkudata(L, 1, bignum_name));
        BN_free(bn);
        bn = nullptr;
        return 0;
    }

    /// Bignum metamethods
    luaL_Reg const MT[] = {
        {"__tostring", [](auto const L) {
             auto const bn = checkbignum(L, 1);
             auto& str = Owned<char, openssl_free<char>>::push(L);
             str = BN_bn2dec(bn);
             if (nullptr == str)
             {
                 openssl_failure(L, "BN_bn2dec");
             }
             lua_pushstring(L, str);
             return 1;
         }},
        {"__gc", l_gc},
        {"__close", l_gc},
        {"__idiv", [](auto const L) {
             auto const a = checkbignum(L, 1);
             auto const b = checkbignum(L, 2);
             auto const r = new_bignum(L);

             if (1 == BN_div(r, nullptr, a, b, get_bn_ctx(L)))
             {
                 return 1;
             }
             else
             {
                 openssl_failure(L, "BN_div");
             }
         }},
        {"__mod", [](auto const L) {
             auto const a = checkbignum(L, 1);
             auto const b = checkbignum(L, 2);
             auto const r = new_bignum(L);

             if (1 == BN_mod(r, a, b, get_bn_ctx(L)))
             {
                 return 1;
             }
             else
             {
                 openssl_failure(L, "BN_mod");
             }
         }},
        {"__unm", [](auto const L) {
             auto const a = checkbignum(L, 1);
             auto& r = push_bignum(L);
             r = BN_dup(a);
             if (nullptr == r)
             {
                 openssl_failure(L, "BN_dup");
             }
             BN_set_negative(r, !BN_is_negative(r));
             return 1;
         }},

        // derived implementations
        {"__add", Wrap<BN_add>::wrap},
        {"__sub", Wrap<BN_sub>::wrap},
        {"__mul", Wrap<BN_mul>::wrap},
        {"__pow", Wrap<BN_exp>::wrap},
        {"__shl", Wrap<BN_lshift>::wrap},
        {"__shr", Wrap<BN_rshift>::wrap},
        {"__eq", compare_bignum<0, true>},
        {"__lt", compare_bignum<-1, true>},
        {"__le", compare_bignum<1, false>},
        {}
    };

    /// Bignum methods, the metatable's __index
    luaL_Reg const Methods[] = {
        /***
        Divide this bignum, computing the quotient and remainder at the
        same time. Both truncate toward zero, like `//` and `%` on bignums.
        @function bignum:div_mod
        @tparam bignum divisor
        @treturn bignum quotient
        @treturn bignum remainder, with the sign of this bignum
        @raise openssl error on failure, such as division by zero
        */
        {"div_mod", Wrap<BN_div>::wrap},

        /***
        Raise this bignum (a) to a power with a modulus
        @function bignum:mod_exp
        @tparam bignum p exponent
        @tparam bignum m modulus
        @treturn bignum (a^p) mod m
        @raise openssl error on failure
        */
        {"mod_exp", Wrap<BN_mod_exp>::wrap},
        {}
    };

} // namespace

auto push_bignum(lua_State* const L) -> BIGNUM*&
{
    auto& bn = *static_cast<BIGNUM**>(lua_newuserdatauv(L, sizeof(BIGNUM*), 0));
    bn = nullptr;

    // Configure userdata's metatable
    if (luaL_newmetatable(L, bignum_name))
    {
        setfuncs(L, MT);
        luaL_newlibtable(L, Methods);
        setfuncs(L, Methods);
        lua_setfield(L, -2, "__index");
    }
    lua_setmetatable(L, -2);
    return bn;
}

auto new_bignum(lua_State* const L) -> BIGNUM*
{
    auto& bn = push_bignum(L);
    bn = BN_new();
    if (nullptr == bn)
    {
        openssl_failure(L, "BN_new");
    }
    return bn;
}

auto l_bignum(lua_State* const L) -> int
{
    // pass existing bignums through
    if (nullptr != luaL_testudata(L, 1, bignum_name))
    {
        lua_settop(L, 1);
        return 1;
    }

    std::size_t len;
    auto const str = luaL_tolstring(L, 1, &len);
    // BN_dec2bn allocates into the empty slot
    auto& r = push_bignum(L);
    // ensure that the whole string was actually used
    if (0 < len && len == static_cast<std::size_t>(BN_dec2bn(&r, str)))
    {
        return 1;
    }
    else
    {
        return luaL_error(L, "bad bignum string");
    }
}

} // namespace myopenssl
