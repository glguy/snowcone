#include "safecall.hpp"

#include "app.hpp"
#include "write.hpp"

extern "C" {
#include "lauxlib.h"
}
#include <ncurses.h>

#include <cstdio>
#include <iostream>

int safecall(lua_State* L, char const* location, int args)
{
    lua_pushcfunction(L, [](auto L){
        auto msg = luaL_tolstring(L, 1, nullptr);
        luaL_traceback(L, L, msg, 1);
        return 1;
    });

    // f a1 a2.. eh
    lua_insert(L, -2-args);
    // eh f a1 a2..

    auto status = lua_pcall(L, args, 0, -2-args);
    if (LUA_OK == status) {
        lua_pop(L, 1);
    } else {
        auto const a = app_ref(L);
        size_t len;
        char const* err = lua_tolstring(L, -1, &len);
        endwin();
        std::cerr << "error in " << location << ": " << err << std::endl;
        lua_pop(L, 2); /* error string, handler */
    }
    return status;
}
