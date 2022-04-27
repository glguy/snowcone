
#include <assert.h>

extern "C" {
#include "lauxlib.h"
}

#include "app.hpp"
#include "lua_uv_filewatcher.hpp"
#include "safecall.hpp"

template<> char const* udata_name<uv_fs_event_t> = "uv_fs_event";

static int l_close(lua_State *L)
{
    auto fs_event = check_udata<uv_fs_event_t>(L, 1);
    uv_close_xx(fs_event, [](auto handle) {
        auto const a = static_cast<app*>(handle->loop->data);
        auto const L = a->L;
        lua_pushnil(L);
        lua_rawsetp(L, LUA_REGISTRYINDEX, handle);
    });
    return 0;
}

void on_file(uv_fs_event_t *handle, const char *filename, int events, int status)
{
    auto const a = static_cast<app*>(handle->loop->data);
    auto const L = a->L;
    lua_rawgetp(L, LUA_REGISTRYINDEX, handle);
    lua_getuservalue(L, -1);
    lua_remove(L, -2);
    safecall(L, "fs_event", 0);
}

static int l_start(lua_State *L)
{
    auto fs_event = check_udata<uv_fs_event_t>(L, 1);
    auto dir = luaL_checkstring(L, 2);
    luaL_checkany(L, 3);
    lua_settop(L, 3);
    lua_setuservalue(L, 1);

    uvok(uv_fs_event_start(fs_event, on_file, dir, UV_FS_EVENT_RECURSIVE));

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
    uvok(uv_fs_event_init(loop, fs_event));

    lua_pushvalue(L, -1);
    lua_rawsetp(L, LUA_REGISTRYINDEX, fs_event);
}
