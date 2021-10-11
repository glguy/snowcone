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

static int finish_safecall(lua_State *L, int status, lua_KContext ctx)
{
    char const* location = (char const*)ctx;

    if (LUA_OK == status) {
        lua_pop(L, 1);
    } else {
        struct app * const a = *app_ref(L);
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

int safecall(lua_State *L, char const* location, int args)
{
    lua_pushcfunction(L, error_handler);
    // f a1 a2.. eh
    lua_insert(L, -2-args);
    // eh f a1 a2..

    lua_KContext ctx = (intptr_t)location;
    return finish_safecall(L, lua_pcallk(L, args, 0, -2-args, ctx, finish_safecall), ctx);
}