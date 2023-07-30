#include "lua_uv_timer.hpp"

#include "app.hpp"
#include "safecall.hpp"
#include "userdata.hpp"
#include "uv.hpp"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include <uv.h>

template<> char const* udata_name<uv_timer_t> = "uv_timer";

namespace {
luaL_Reg const MT[] = {
    {"close", [](auto const L) {
        auto const timer = check_udata<uv_timer_t>(L, 1);
        if (!uv_is_closing(handle_cast(timer))) {
            uv_close_xx(timer, [](auto const handle) {
                auto const L = App::from_loop(handle->loop)->L;
                lua_pushnil(L);
                lua_rawsetp(L, LUA_REGISTRYINDEX, handle);
            });
        }
        return 0;
    }},

    {"start", [](auto const L) {
        auto const timer = check_udata<uv_timer_t>(L, 1);
        auto const start = luaL_checkinteger(L, 2);
        auto const repeat = luaL_checkinteger(L, 3);
        luaL_checkany(L, 4);
        lua_settop(L, 4);

        if (uv_is_closing(handle_cast(timer))) {
            return luaL_error(L, "Attempted to start a closed timer");
        }

        // store the callback function
        lua_setuservalue(L, 1);

        uvok(uv_timer_start(timer, [](auto const timer) {
            auto const L = App::from_loop(timer->loop)->L;
            lua_rawgetp(L, LUA_REGISTRYINDEX, timer);
            lua_getuservalue(L, -1);
            lua_insert(L, -2);
            safecall(L, "timer", 1);
            }, start, repeat));

        return 0;
    }},

    {"stop", [](auto const L) {
        auto const timer = check_udata<uv_timer_t>(L, 1);

        // forget the current callback.
        lua_pushnil(L);
        lua_setuservalue(L, -2);

        if (uv_is_closing(handle_cast(timer))) {
            return luaL_error(L, "Attempted to stop a closed timer");
        }

        uvok(uv_timer_stop(timer));
        return 0;
    }},

    {}
};
}

void push_new_uv_timer(lua_State *L, uv_loop_t *loop)
{
    auto timer = new_udata<uv_timer_t>(L, [L](){
        // Build metatable the first time
        luaL_setfuncs(L, MT, 0);
        lua_pushvalue(L, -1);
        lua_setfield(L, -2, "__index");
    });
    uvok(uv_timer_init(loop, timer));

    // Keep the timer alive until it is closed in uv
    lua_pushvalue(L, -1);
    lua_rawsetp(L, LUA_REGISTRYINDEX, timer);
}
