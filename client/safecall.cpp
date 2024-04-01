#include "safecall.hpp"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include <ncurses.h>

#include <cstdio>
#include <iostream>

int safecall(lua_State* const L, char const* const location, int const args)
{
    lua_pushcfunction(L, [](auto const L){
        auto const msg = luaL_tolstring(L, 1, nullptr);
        luaL_traceback(L, L, msg, 1);
        return 1;
    });

    // f a1 a2.. eh
    lua_insert(L, -2-args);
    // eh f a1 a2..

    auto const status = lua_pcall(L, args, 0, -2-args);
    if (LUA_OK == status) {
        lua_pop(L, 1); /* handler */
    } else {
        auto const err = lua_tolstring(L, -1, nullptr);
        endwin();
        std::cerr << "error in " << location << ": " << err << std::endl;
        lua_pop(L, 2); /* error string, handler */
    }
    return status;
}
