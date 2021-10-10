#include "lauxlib.h"
#include <ncurses.h>
#include <stdio.h>

#include "safecall.h"
#include "app.h"
#include "write.h"

static int error_handler(lua_State *L)
{
    const char* msg = luaL_tolstring(L, 1, NULL);
    luaL_traceback(L, L, msg, 1);
    return 1;
}

int safecall(lua_State *L, char const* location, int args, int results)
{
    lua_pushcfunction(L, error_handler);
    // f a1 a2.. eh
    lua_insert(L, -2-args);
    // eh f a1 a2..

    int r = lua_pcall(L, args, results, -2-args);
    if (LUA_OK == r) {
        lua_remove(L, -1-results);
    } else {
        struct app * const a = *app_ref(L);
        size_t len;
        char const* err = luaL_tolstring(L, -1, &len);
        if (a->console) {
            to_write(a->console, err, len);
            to_write(a->console, "\n", 1);
        } else {
            endwin();
            fprintf(stderr, "error in %s: %s\n", location, err);
        }
        lua_pop(L, 3); /* error, error string, handler */
    }

    return r;
}