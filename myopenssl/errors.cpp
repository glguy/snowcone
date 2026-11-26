// Raising OpenSSL errors into Lua, and the per-call error boundary.

#include "errors.hpp"

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

/// The closure setfuncs registers: upvalue 1 is a light userdata pointing
/// at the luaL_Reg entry to call. Clears the OpenSSL error queue, calls it,
/// and turns an escaping C++ exception into a Lua error.
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

    // The queue is drained here rather than through ERR_print_errors_cb, so
    // a memory error from the buffer never unwinds through OpenSSL's frames.
    // Each line is ERR_print_errors_cb's, less its thread id.
    char const* file;
    int line;
    char const* func;
    char const* data;
    int flags;
    while (auto const code = ERR_get_error_all(&file, &line, &func, &data, &flags))
    {
        // data and file are valid only until the next call into ERR
        char text[256];
        ERR_error_string_n(code, text, sizeof text);
        char entry[1024];
        std::snprintf(entry, sizeof entry, "%s:%s:%d:%s", text, file, line, flags & ERR_TXT_STRING ? data : "");
        luaL_addchar(&B, '\n');
        luaL_addstring(&B, entry);
    }

    luaL_pushresult(&B);
    lua_error(L);
    std::abort();
}
