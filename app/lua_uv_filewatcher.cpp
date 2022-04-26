
#include <assert.h>

extern "C" {
#include "lauxlib.h"
}

#include "app.hpp"
#include "lua_uv_filewatcher.hpp"
#include "safecall.hpp"

static char const* const type_name = "uv_fs_event";

template<> char const* udata_name<uv_fs_event_t> = "uv_fs_event";

static void on_close(uv_handle_t *handle)
{
    auto const a = static_cast<app*>(handle->loop->data);
    lua_State * const L = a->L;
    lua_pushnil(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, handle);
}

static int l_close(lua_State *L)
{
    auto fs_event = check_udata<uv_fs_event_t>(L, 1);
    uv_close((uv_handle_t*)fs_event, on_close);
    return 0;
}

void on_file(uv_fs_event_t *handle, const char *filename, int events, int status)
{
    auto const a = static_cast<app*>(handle->loop->data);
    lua_State * const L = a->L;
    lua_rawgetp(L, LUA_REGISTRYINDEX, handle);
    lua_getuservalue(L, -1);
    lua_remove(L, -2);
    safecall(L, "fs_event", 0);
}

static int l_start(lua_State *L)
{
    auto fs_event = check_udata<uv_fs_event_t>(L, 1);
    char const* dir = luaL_checkstring(L, 2);
    luaL_checkany(L, 3);
    lua_settop(L, 3);
    lua_setuservalue(L, 1);

    int r = uv_fs_event_start(fs_event, on_file, dir, UV_FS_EVENT_RECURSIVE);
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
    auto fs_event = new_udata<uv_fs_event_t>(L, [L]() {
        luaL_setfuncs(L, MT, 0);
        lua_pushvalue(L, -1);
        lua_setfield(L, -2, "__index");
    });

    lua_pushvalue(L, -1);
    lua_rawsetp(L, LUA_REGISTRYINDEX, fs_event);

    int r = uv_fs_event_init(loop, fs_event);
    assert(0 == r);
}
