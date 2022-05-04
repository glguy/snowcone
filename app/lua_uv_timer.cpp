#include "lua_uv_timer.hpp"

#include "app.hpp"
#include "safecall.hpp"
#include "userdata.hpp"

extern "C" {
#include "lauxlib.h"
}

template<> char const* udata_name<uv_timer_t> = "uv_timer";

namespace {
luaL_Reg const MT[] = {
    {"close", [](auto L) {
        auto timer = check_udata<uv_timer_t>(L, 1);
        uv_close_xx(timer, [](auto handle) {
            auto const L = static_cast<app*>(handle->loop->data)->L;
            lua_pushnil(L);
            lua_rawsetp(L, LUA_REGISTRYINDEX, handle);
        });
        return 0;
    }},

    {"start", [](auto L) {
        auto timer = check_udata<uv_timer_t>(L, 1);
        auto start = luaL_checkinteger(L, 2);
        auto repeat = luaL_checkinteger(L, 3);
        luaL_checkany(L, 4);
        lua_settop(L, 4);

        lua_setuservalue(L, 1);
        uvok(uv_timer_start(timer, [](uv_timer_t *timer) {
            auto const a = static_cast<app*>(timer->loop->data);
            auto const L = a->L;
            lua_rawgetp(L, LUA_REGISTRYINDEX, timer);
            lua_getuservalue(L, -1);
            lua_remove(L, -2);

            safecall(L, "timer", 0);
            }, start, repeat));

        return 0;
    }},

    {"stop", [](auto L) {
        auto timer = check_udata<uv_timer_t>(L, 1);
        uvok(uv_timer_stop(timer));
        return 0;
    }},

    {}
};
}

void push_new_uv_timer(lua_State *L, uv_loop_t *loop)
{
    auto timer = new_udata<uv_timer_t>(L, [L](){
        luaL_setfuncs(L, MT, 0);
        lua_pushvalue(L, -1);
        lua_setfield(L, -2, "__index");
    });

    lua_pushvalue(L, -1);
    lua_rawsetp(L, LUA_REGISTRYINDEX, timer);

    uvok(uv_timer_init(loop, timer));
}
