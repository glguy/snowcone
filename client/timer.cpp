#include "timer.hpp"

#include "app.hpp"
#include "safecall.hpp"
#include "userdata.hpp"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include <boost/asio/steady_timer.hpp>

#include <chrono> // durations
#include <memory>

using Timer = boost::asio::steady_timer;

template<> char const* udata_name<Timer> = "steady_timer";

namespace {

luaL_Reg const MT[] {
    {"__gc", [](auto const L) {
        auto const timer = check_udata<Timer>(L, 1);
        lua_pushnil(L);
        lua_rawsetp(L, LUA_REGISTRYINDEX, timer);
        timer->~Timer();
        return 0;
    }},

    {}
};

luaL_Reg const Methods[] {
    {"start", [](auto const L) {
        auto const timer = check_udata<Timer>(L, 1);
        auto const start = luaL_checkinteger(L, 2);
        luaL_checkany(L, 3);
        lua_settop(L, 3);

        // store the callback function
        lua_rawsetp(L, LUA_REGISTRYINDEX, timer);

        timer->expires_after(std::chrono::milliseconds{start});
        timer->async_wait([L, timer](auto const error) {
            if (!error) {
                // get the callback
                lua_rawgetp(L, LUA_REGISTRYINDEX, timer);
                // forget the callback
                lua_pushnil(L);
                lua_rawsetp(L, LUA_REGISTRYINDEX, timer);
                // invoke the callback
                safecall(L, "timer", 0);
            }});

        return 0;
    }},

    {"cancel", [](auto const L) {
        auto const timer = check_udata<Timer>(L, 1);
        timer->cancel();

        // forget the current callback.
        lua_pushnil(L);
        lua_rawsetp(L, LUA_REGISTRYINDEX, timer);

        return 0;
    }},

    {}
};

} // namespace

auto l_new_timer(lua_State *const L) -> int
{
    auto const timer = new_udata<Timer>(L, 0, [L](){
        // Build metatable the first time
        luaL_setfuncs(L, MT, 0);
        luaL_newlibtable(L, Methods);
        luaL_setfuncs(L, Methods, 0);
        lua_setfield(L, -2, "__index");
    });
    std::construct_at(timer, App::from_lua(L)->io_context);
    return 1;
}
