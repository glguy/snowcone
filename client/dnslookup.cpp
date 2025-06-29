#include "dnslookup.hpp"

#include "app.hpp"
#include "safecall.hpp"
#include "strings.hpp"

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <memory>

auto l_dnslookup(lua_State* const L) -> int
{
    using Resolver = boost::asio::ip::tcp::resolver;

    auto const hostname = check_string_view(L, 1);
    luaL_checkany(L, 2); // callback
    lua_settop(L, 2);
    auto const app = App::from_lua(L);
    auto const resolver = std::make_shared<Resolver>(app->get_executor());

    // Store the callback
    lua_rawsetp(L, LUA_REGISTRYINDEX, resolver.get());

    resolver->async_resolve(hostname, "",
        [L = app->get_lua(), resolver](boost::system::error_code const error, Resolver::results_type const results)
    {
        // get the callback
        lua_rawgetp(L, LUA_REGISTRYINDEX, resolver.get());

        // forget the callback
        lua_pushnil(L);
        lua_rawsetp(L, LUA_REGISTRYINDEX, resolver.get());

        if (error)
        {
            push_string(L, error.message());
            safecall(L, "dnslookup failure", 1);
        }
        else
        {
            lua_pushnil(L); // nil error message
            for (auto&& result : results)
            {
                push_string(L, result.endpoint().address().to_string());
            }
            safecall(L, "dnslookup success", 1 + results.size());
        }
    });

    return 1;
}
