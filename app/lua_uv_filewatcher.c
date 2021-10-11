
#include <assert.h>

#include "app.h"
#include "lua_uv_filewatcher.h"
#include "lauxlib.h"
#include "safecall.h"

static char const* const typename = "uv_fs_event";

static void on_close(uv_handle_t *handle)
{
    struct app * const a = handle->loop->data;
    lua_State * const L = a->L;
    lua_pushnil(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, handle);
}

static int l_close(lua_State *L)
{
    uv_fs_event_t *fs_event = luaL_checkudata(L, 1, typename);
    uv_close((uv_handle_t*)fs_event, on_close);
    return 0;
}

void on_file(uv_fs_event_t *handle, const char *filename, int events, int status)
{
    struct app * const a = handle->loop->data;
    lua_State * const L = a->L;
    lua_rawgetp(L, LUA_REGISTRYINDEX, handle);
    lua_getuservalue(L, -1);
    lua_remove(L, -2);
    safecall(L, "fs_event", 0);
}

static int l_start(lua_State *L)
{
    uv_fs_event_t *fs_event = luaL_checkudata(L, 1, typename);
    char const* dir = luaL_checkstring(L, 2);
    luaL_checkany(L, 3);
    lua_settop(L, 3);
    lua_setuservalue(L, 1);

    int r = uv_fs_event_start(fs_event, on_file, dir, 0);
    assert(0 == r);

    return 0;
}

static luaL_Reg MT[] = {
    {"close", l_close},
    {"start", l_start},
    {}
};

void push_new_fs_event(lua_State *L, uv_loop_t *loop)
{
    uv_fs_event_t *fs_event = lua_newuserdata(L, sizeof *fs_event);

    if (luaL_newmetatable(L, typename)) {
        luaL_setfuncs(L, MT, 0);
        lua_pushvalue(L, -1);
        lua_setfield(L, -2, "__index");
    }
    lua_setmetatable(L, -2);

    lua_pushvalue(L, -1);
    lua_rawsetp(L, LUA_REGISTRYINDEX, fs_event);

    int r = uv_fs_event_init(loop, fs_event);
    assert(0 == r);
}
