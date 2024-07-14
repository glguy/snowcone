#include "errors.hpp"

#include "invoke.hpp"

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <openssl/err.h>

#include <cstdlib>

[[noreturn]]
auto myopenssl::openssl_failure(lua_State* L, char const* func) -> void
{
    luaL_Buffer B;
    luaL_buffinit(L, &B);
    luaL_addstring(&B, "OpenSSL error in ");
    luaL_addstring(&B, func);

    auto const cb = [&B](char const* str, size_t len) -> int {
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
