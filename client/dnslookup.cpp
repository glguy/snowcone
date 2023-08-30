#include "dnslookup.hpp"

#include "app.hpp"
#include "safecall.hpp"
#include "userdata.hpp"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include <chrono> // durations

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

}

auto l_dnslookup(lua_State *const L) -> int
{
    std::size_t len;
    auto const hostname = luaL_checklstring(L, 1, &len);
    luaL_checkany(L, 2);
    lua_settop(L, 2);

    auto const resolver = new_udata<Resolver>(L, 0, [L](){
        // Build metatable the first time
        luaL_setfuncs(L, MT, 0);
        luaL_newlib(L, Methods);
        lua_setfield(L, -2, "__index");
    });

    lua_rotate(L, -2, 1); // swap the callback and the udata

    // Store the callback
    lua_rawsetp(L, LUA_REGISTRYINDEX, resolver);

    new (resolver) Resolver {App::from_lua(L)->io_context};
    resolver->async_resolve(std::string_view{hostname, len}, "", [L, resolver](
        boost::system::error_code const& error,
        Resolver::results_type results
    ) {
        // get the callback
        lua_rawgetp(L, LUA_REGISTRYINDEX, resolver);
        
        // forget the callback
        lua_pushnil(L);
        lua_rawsetp(L, LUA_REGISTRYINDEX, resolver);

        int returns;

        if (error)
        {
            returns = 2;
            lua_pushnil(L);
            lua_pushstring(L, error.message().c_str());
        }
        else
        {
            returns = 1;
            lua_createtable(L, results.size(), 0);
            lua_Integer i = 1;
            for (auto && result : results)
            {
                auto const address = result.endpoint().address().to_string();
                lua_pushlstring(L, address.data(), address.size());
                lua_rawseti(L, -2, i++);
            }
        }
        safecall(L, "dnslookup callback", returns);
    });

    return 1;
}
