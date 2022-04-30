extern "C" {
#include "lauxlib.h"
}

#include <ncurses.h>
#include <stdio.h>

#include "app.hpp"
#include "safecall.hpp"
#include "write.hpp"

int safecall(lua_State *L, char const* location, int args)
{
    lua_pushcfunction(L, [](auto L){
        auto msg = luaL_tolstring(L, 1, NULL);
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
        if (a->console) {
            to_write(a->console, err, len);
            to_write(a->console, "\n", 1);
        } else {
            endwin();
            fprintf(stderr, "error in %s: %s\n", location, err);
        }
        lua_pop(L, 2); /* error string, handler */
    }
    return status;
}