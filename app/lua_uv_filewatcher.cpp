#include "lua_uv_filewatcher.hpp"

#include "app.hpp"
#include "safecall.hpp"
#include "userdata.hpp"
#include "uv.hpp"

extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

template<> char const* udata_name<uv_fs_event_t> = "uv_fs_event";

namespace {

void on_file(uv_fs_event_t *handle, const char *filename, int events, int status)
{
    auto const a = app::from_loop(handle->loop);
    auto const L = a->L;
    lua_rawgetp(L, LUA_REGISTRYINDEX, handle);
    lua_getuservalue(L, -1);
    lua_remove(L, -2);

    lua_pushstring(L, filename);
    lua_pushinteger(L, events);
    safecall(L, "fs_event", 2);
}

luaL_Reg const MT[] = {
    {"close", [](lua_State *L) -> int {
        auto fs_event = check_udata<uv_fs_event_t>(L, 1);
        if (!uv_is_closing(handle_cast(fs_event))) {
            uv_close_xx(fs_event, [](auto handle) {
                auto const a = app::from_loop(handle->loop);
                auto const L = a->L;
                lua_pushnil(L);
                lua_rawsetp(L, LUA_REGISTRYINDEX, handle);
            });
        }
        return 0;
    }},

    {"start", [](lua_State* L) -> int {
        auto fs_event = check_udata<uv_fs_event_t>(L, 1);
        auto dir = luaL_checkstring(L, 2);
        luaL_checkany(L, 3);
        lua_settop(L, 3);
        lua_setuservalue(L, 1);

        if (uv_is_closing(handle_cast(fs_event))) {
            return luaL_error(L, "Attempted to start a closed fs_event");
        }

        uvok(uv_fs_event_start(fs_event, on_file, dir, UV_FS_EVENT_RECURSIVE));

        return 0;
    }},

    {"stop", [](lua_State* L) -> int {
        auto fs_event = check_udata<uv_fs_event_t>(L, 1);

        if (uv_is_closing(handle_cast(fs_event))) {
            return luaL_error(L, "Attempted to stop a closed fs_event");
        }

        uvok(uv_fs_event_stop(fs_event));
        return 0;
    }},

    {} // MT terminator
};

} // namespace

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
