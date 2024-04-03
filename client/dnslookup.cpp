#include "dnslookup.hpp"

#include "app.hpp"
#include "safecall.hpp"
#include "strings.hpp"
#include "userdata.hpp"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include <memory>

using Resolver = boost::asio::ip::tcp::resolver;

template<> char const* udata_name<Resolver> = "dnslookup";

namespace {

luaL_Reg const MT[] = {
    {"__gc", [](auto const L) {
        auto const resolver = check_udata<Resolver>(L, 1);
        lua_pushnil(L);
        lua_rawsetp(L, LUA_REGISTRYINDEX, resolver);
        resolver->~Resolver();
        return 0;
    }},
    {}
};

luaL_Reg const Methods[] = {
    {"cancel", [](auto const L) {
        auto const resolver = check_udata<Resolver>(L, 1);
        lua_pushnil(L);
        lua_rawsetp(L, LUA_REGISTRYINDEX, resolver);
        resolver->cancel();
        return 0;
    }},
    {}
};

} // namespace

auto l_dnslookup(lua_State *const L) -> int
{
    auto const hostname = check_string_view(L, 1);
    luaL_checkany(L, 2); // callback
    lua_settop(L, 2);
    auto const app = App::from_lua(L);

    auto const resolver = new_udata<Resolver>(L, 0, [L](){
        // Build metatable the first time
        luaL_setfuncs(L, MT, 0);
        luaL_newlibtable(L, Methods);
        luaL_setfuncs(L, Methods, 0);
        lua_setfield(L, -2, "__index");
    });
    std::construct_at(resolver, app->get_executor());

    lua_rotate(L, -2, 1); // swap the callback and the udata

    // Store the callback
    lua_rawsetp(L, LUA_REGISTRYINDEX, resolver);

    resolver->async_resolve(hostname, "", [L = app->get_lua(), resolver](
        boost::system::error_code const error,
        Resolver::results_type const results
    ) {
        // on abort the callback has already been cleaned up
        if (boost::asio::error::operation_aborted == error) return;

        // get the callback
        lua_rawgetp(L, LUA_REGISTRYINDEX, resolver);

        // forget the callback
        lua_pushnil(L);
        lua_rawsetp(L, LUA_REGISTRYINDEX, resolver);

        int returns;

        if (error)
        {
            returns = 2;
            luaL_pushfail(L);
            lua_pushstring(L, error.message().c_str());
        }
        else
        {
            returns = 1;
            lua_createtable(L, results.size(), 0);
            lua_Integer i = 1;
            for (auto const& result : results)
            {
                push_string(L, result.endpoint().address().to_string());
                lua_rawseti(L, -2, i++);
            }
        }
        safecall(L, "dnslookup callback", returns);
    });

    return 1;
}
