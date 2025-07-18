#include "timer.hpp"

#include "app.hpp"
#include "safecall.hpp"
#include "userdata.hpp"

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <boost/asio/steady_timer.hpp>

#include <chrono> // durations
#include <memory>

using Timer = boost::asio::steady_timer;

template <>
char const* udata_name<Timer> = "steady_timer";

namespace {

auto l_gc(lua_State* const L) -> int
{
    auto const timer = check_udata<Timer>(L, 1);
    lua_pushnil(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, timer);
    std::destroy_at(timer);
    return 0;
}

luaL_Reg const MT[]{
    {"__gc", l_gc},
    {}
};

luaL_Reg const Methods[]{
    /// @param self
    /// @param delay milliseconds
    /// @param callback
    {"start", [](auto const L) {
         auto const timer = check_udata<Timer>(L, 1);
         auto const start = luaL_checkinteger(L, 2);
         luaL_checkany(L, 3);
         lua_settop(L, 3);

         // store the callback function
         lua_rawsetp(L, LUA_REGISTRYINDEX, timer);

         auto const app = App::from_lua(L);

         timer->expires_after(std::chrono::milliseconds{start});
         timer->async_wait([L = app->get_lua(), timer](auto const error) {
            if (not error) {
                // get the callback
                lua_rawgetp(L, LUA_REGISTRYINDEX, timer);
                // forget the callback
                lua_pushnil(L);
                lua_rawsetp(L, LUA_REGISTRYINDEX, timer);
                // invoke the callback
                safecall(L, "timer", 0);
            } });

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

auto l_new_timer(lua_State* const L) -> int
{
    auto const timer = new_udata<Timer>(L, 0, [L] {
        // Build metatable the first time
        luaL_setfuncs(L, MT, 0);
        luaL_newlibtable(L, Methods);
        luaL_setfuncs(L, Methods, 0);
        lua_setfield(L, -2, "__index");
    });
    std::construct_at(timer, App::from_lua(L)->get_context());
    return 1;
}
