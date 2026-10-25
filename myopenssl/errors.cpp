#include "errors.hpp"

#include "invoke.hpp"

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <openssl/err.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>

namespace {

/// Upvalue 1 is the luaL_Reg entry to call
auto dispatch(lua_State* const L) -> int
{
    auto const reg = static_cast<luaL_Reg const*>(lua_touserdata(L, lua_upvalueindex(1)));
    char message[256];
    try
    {
        ERR_clear_error();
        return reg->func(L);
    }
    catch (std::exception const& e)
    {
        std::snprintf(message, sizeof message, "%s", e.what());
    }
    catch (...)
    {
        std::snprintf(message, sizeof message, "unknown C++ exception");
    }
    return luaL_error(L, "%s", message);
}

} // namespace

auto myopenssl::setfuncs(lua_State* const L, luaL_Reg const* regs) -> void
{
    for (; regs->name; regs++)
    {
        if (0 == std::strcmp("__gc", regs->name) || 0 == std::strcmp("__close", regs->name))
        {
            lua_pushcfunction(L, regs->func);
        }
        else
        {
            lua_pushlightuserdata(L, const_cast<luaL_Reg*>(regs));
            lua_pushcclosure(L, dispatch, 1);
        }
        lua_setfield(L, -2, regs->name);
    }
}

[[noreturn]]
auto myopenssl::openssl_failure(lua_State* L, char const* func) -> void
{
    lua_pushfstring(L, "OpenSSL error in %s", func);
    openssl_failure_message(L, lua_tostring(L, -1));
}

[[noreturn]]
auto myopenssl::openssl_failure_message(lua_State* L, char const* message) -> void
{
    luaL_Buffer B;
    luaL_buffinit(L, &B);
    luaL_addstring(&B, message);

    auto const cb = [&B](char const* str, size_t len) -> int {
        // each line arrives with its own newline; move it to the front
        if (0 < len && '\n' == str[len - 1])
        {
            len--;
        }
        luaL_addchar(&B, '\n');
        luaL_addlstring(&B, str, len);
        return 1; // 1:success 0:failure
    };

    using Invoker = Invoke<decltype(cb)>;
    ERR_print_errors_cb(Invoker::invoke, Invoker::prep(cb));

    luaL_pushresult(&B);
    lua_error(L);
    std::abort();
}
