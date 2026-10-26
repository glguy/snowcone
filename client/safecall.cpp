#include "safecall.hpp"

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include "strings.hpp"

#include <ncurses.h>

#include <cstdio>

namespace {
int failures = 0;
}

auto safecall_failures() -> int
{
    return failures;
}

int safecall(lua_State* const L, std::string_view const location, int const args)
{
    lua_pushcfunction(L, [](auto const L) {
        auto const msg = luaL_tolstring(L, 1, nullptr);
        luaL_traceback(L, L, msg, 1);
        return 1;
    });

    // f a1 a2.. eh
    lua_insert(L, -2 - args);
    // eh f a1 a2..

    auto const status = lua_pcall(L, args, 0, -2 - args);
    if (LUA_OK == status)
    {
        lua_pop(L, 1); /* handler */
    }
    else
    {
        ++failures;
        std::size_t len;
        auto const err = lua_tolstring(L, -1, &len);
        endwin();
        // The message may quote data from a server or an HTTP client
        std::fprintf(stderr, "error in %.*s: ", static_cast<int>(location.size()), location.data());
        write_escaped(stderr, {err, len});
        std::fputc('\n', stderr);
        lua_pop(L, 2); /* error string, handler */
    }
    return status;
}
