#include "to_toml.hpp"
#include "toml.hpp"

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <functional>
#include <sstream>
#include <string>
#include <string_view>

namespace {

/// @brief Determine how long the array is on the top of the stack
/// @param L Lua state
/// @return 0 for failure, positive number for length of valid array
auto is_lua_array(lua_State* const L) -> int
{
    // Uses the pidgeon-hole principle to check if a table has
    // only positive integer keys in the range of 1 to N for
    // some N.
    lua_Integer counter = 0;
    lua_Integer largest = 0;

    for (lua_pushnil(L); 0 != lua_next(L, -2);)
    {
        lua_pop(L, 1); // discard the value

        if (lua_isinteger(L, -1))
        {
            auto const i = lua_tointeger(L, -1);
            if (i > 0)
            {
                if (i > largest)
                {
                    largest = i;
                }
                ++counter;
                continue;
            }
        }

        lua_pop(L, 1); // discard the key
        return 0;
    }

    if (counter != largest)
    {
        return 0;
    }

    return counter;
}

auto mk_a_case(toml::array& a)
{
    return [&a](toml::node&& v) {
        a.push_back(std::move(v));
    };
}

auto mk_t_case(toml::table& t, std::string_view const key)
{
    return [&t, key](toml::node&& v) {
        t.insert(key, std::move(v));
    };
}

auto with_toml(lua_State* const L, std::invocable<toml::node&&> auto k) -> void
{
    switch (lua_type(L, -1))
    {
    case LUA_TBOOLEAN: {
        auto const b = lua_toboolean(L, -1);
        lua_pop(L, 1); // drop the boolean
        return k(toml::value<bool>(b));
    }

    case LUA_TNUMBER:
        if (lua_isinteger(L, -1))
        {
            auto const n = lua_tointeger(L, -1);
            lua_pop(L, 1); // drop the number
            return k(toml::value<std::int64_t>(n));
        }
        else
        {
            auto const n = lua_tonumber(L, -1);
            lua_pop(L, 1); // drop the number
            return k(toml::value<double>(n));
        }

    case LUA_TSTRING: {
        std::size_t len;
        auto const str = lua_tolstring(L, -1, &len);
        toml::value<std::string> v{str, len};
        lua_pop(L, 1); // drop the string
        return k(std::move(v));
    }

    case LUA_TTABLE:
        if (auto const n = is_lua_array(L); 0 < n)
        {
            toml::array a;
            a.reserve(n);

            for (lua_Integer i = 0; i < n; i++)
            {
                lua_geti(L, -1, i + 1);
                with_toml(L, mk_a_case(a));
            }

            lua_pop(L, 1); // drop the array
            return k(std::move(a));
        }
        else
        {
            toml::table t;

            for (lua_pushnil(L); 0 != lua_next(L, -2);)
            {
                if (LUA_TSTRING != lua_type(L, -2))
                {
                    throw std::runtime_error{"non-string table key"};
                }

                std::size_t len;
                auto const str = lua_tolstring(L, -2, &len);
                std::string_view const key{str, len};

                with_toml(L, mk_t_case(t, key));
            }

            lua_pop(L, 1); // drop the table
            return k(std::move(t));
        }

    default:
        throw std::runtime_error{"unsupported value type"};
    }
}

} // namespace

auto mytoml::l_to_toml(lua_State* const L) -> int
{
    lua_settop(L, 1);
    try
    {
        std::ostringstream os;
        with_toml(L, [&os](toml::node&& t) -> void {
            os << toml::node_view{t};
        });
        lua_pushlstring(L, os.str().data(), os.str().size());
        return 1;
    }
    catch (std::exception const& ex)
    {
        luaL_pushfail(L);
        lua_pushstring(L, ex.what());
        return 2;
    }
}
