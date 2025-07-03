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

auto with_toml(lua_State* const L, std::invocable<toml::node&&> auto k) -> void
{
    using namespace std::placeholders;

    switch (lua_type(L, -1))
    {
    case LUA_TBOOLEAN: {
        k(toml::value<bool>{lua_toboolean(L, -1)});
        break;
    }

    case LUA_TNUMBER:
        if (lua_isinteger(L, -1))
        {
            k(toml::value<std::int64_t>{lua_tointeger(L, -1)});
        }
        else
        {
            k(toml::value<double>{lua_tonumber(L, -1)});
        }
        break;

    case LUA_TSTRING: {
        std::size_t len;
        auto const str = lua_tolstring(L, -1, &len);
        k(toml::value<std::string>{str, len});
        break;
    }

    case LUA_TTABLE:
        lua_pushnil(L);
        if (0 == lua_next(L, -2))
        {
            k(toml::table{});
        }
        else if (lua_isinteger(L, -2))
        {
            lua_Integer entries{0};
            lua_Integer max_key{0};

            toml::array a;

            do
            {
                entries++;
                auto const key = lua_tonumber(L, -2);
                if (key < 1)
                {
                    throw std::runtime_error{"negative array key"};
                }
                if (key > max_key)
                {
                    max_key = key;
                }
                with_toml(L, std::bind(&toml::array::push_back<toml::node>, std::ref(a), _1, toml::preserve_source_value_flags));
            }
            while (0 != lua_next(L, -2));

            if (entries != max_key)
            {
                throw std::runtime_error{"incomplete array"};
            }

            k(std::move(a));
        }
        else
        {
            toml::table t;

            do
            {
                if (LUA_TSTRING != lua_type(L, -2))
                {
                    throw std::runtime_error{"non-string table key"};
                }

                std::size_t len;
                auto const str = lua_tolstring(L, -2, &len);
                with_toml(L, std::bind(&toml::table::insert<std::string_view&, toml::node>, std::ref(t), std::string_view{str, len}, _1, toml::preserve_source_value_flags));
            }
            while (0 != lua_next(L, -2));

            k(std::move(t));
        }

        break;

    default:
        throw std::runtime_error{"unsupported value type"};
    }

    lua_pop(L, 1);
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
        auto const output = std::move(os).str();
        lua_pushlstring(L, output.data(), output.size());
        return 1;
    }
    catch (std::exception const& ex)
    {
        luaL_pushfail(L);
        lua_pushstring(L, ex.what());
        return 2;
    }
}
