#include "dnslookup.hpp"

#include "app.hpp"
#include "boundary.hpp"
#include "safecall.hpp"
#include "strings.hpp"
#include "userdata.hpp"

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <climits>
#include <memory>

namespace {

using Resolver = boost::asio::ip::tcp::resolver;

/// One lookup, owned by its completion handler. While armed, the callback
/// is kept in the registry under this object's address. It is not a LuaRef:
/// the io_context destroys a handler still queued only after lua_close, and
/// that destruction must not touch the state.
struct Lookup
{
    Resolver resolver;
    bool armed = true;

    explicit Lookup(boost::asio::io_context& context)
        : resolver{context}
    {
    }

    /// Forget the callback, leaving it on the stack when push is set
    auto disarm(lua_State* const L, bool const push) -> void
    {
        if (push)
        {
            lua_rawgetp(L, LUA_REGISTRYINDEX, this);
        }
        lua_pushnil(L);
        lua_rawsetp(L, LUA_REGISTRYINDEX, this);
        armed = false;
    }
};

/// The Lua handle. It doesn't keep the lookup going: a lookup runs to the
/// end, or until canceled, whether or not its handle is collected.
struct Handle
{
    std::weak_ptr<Lookup> lookup;
};

} // namespace

template <>
char const* const udata_name<Handle> = "dnslookup";

namespace {

/// The userdata stays reachable after finalization (resurrection, weak-keyed
/// tables), so the payload is emptied rather than destroyed. Collecting the
/// handle doesn't cancel the lookup.
auto l_gc(lua_State* const L) -> int
{
    check_udata<Handle>(L, 1)->lookup.reset();
    return 0;
}

/// Drop the callback so it never runs. A getaddrinfo already running can't
/// be interrupted (REVIEW.md F-022), but its result is discarded. Does
/// nothing once the lookup has finished or been canceled.
auto l_cancel(lua_State* const L) -> int
{
    if (auto const lookup = check_udata<Handle>(L, 1)->lookup.lock())
    {
        if (lookup->armed)
        {
            lookup->disarm(L, false);
            lookup->resolver.cancel();
        }
    }
    return 0;
}

luaL_Reg const MT[]{
    {"__gc", boundary<l_gc>},
    {}
};

luaL_Reg const Methods[]{
    {"cancel", boundary<l_cancel>},
    {}
};

} // namespace

auto l_dnslookup(lua_State* const L) -> int
{
    auto const hostname = check_c_string(L, 1);
    luaL_checkany(L, 2); // callback
    lua_settop(L, 2);
    auto const app = App::from_lua(L);

    auto const handle = new_udata<Handle>(L, 0, [L] {
        // Build metatable the first time
        luaL_setfuncs(L, MT, 0);
        luaL_newlibtable(L, Methods);
        luaL_setfuncs(L, Methods, 0);
        lua_setfield(L, -2, "__index");
        // Keep __gc out of reach of Lua code
        lua_pushboolean(L, false);
        lua_setfield(L, -2, "__metatable");
    });
    std::construct_at(handle);

    auto const lookup = std::make_shared<Lookup>(app->get_context());
    handle->lookup = lookup;

    // Store the callback
    lua_pushvalue(L, 2);
    lua_rawsetp(L, LUA_REGISTRYINDEX, lookup.get());

    lookup->resolver.async_resolve(hostname, "",
        [L = app->get_lua(), lookup]
        (boost::system::error_code const error,
         Resolver::results_type const results
    ) {
        if (not lookup->armed)
        {
            return; // canceled
        }
        lookup->disarm(L, true);

        if (error)
        {
            push_string(L, error.message());
            safecall(L, "dnslookup failure", 1);
        }
        // One stack slot per address; a large answer must not overflow
        else if (results.size() >= INT_MAX or not lua_checkstack(L, static_cast<int>(results.size()) + 1))
        {
            lua_pushliteral(L, "dnslookup: too many results");
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
