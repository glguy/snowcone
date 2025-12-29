#include "parse_toml.hpp"
#include "toml.hpp"

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

namespace {

auto push_toml(lua_State* const L, toml::value const& value) -> void
{
    switch (value.type()) {
        case toml::value_t::array: {
            auto const & array = value.as_array();
            lua_createtable(L, array.size(), 0);
            lua_Integer i = 1;
            for (auto& x : array)
            {
                push_toml(L, x);
                lua_rawseti(L, -2, i++);
            }
            break;
        }

        case toml::value_t::table: {
            auto const & table = value.as_table();
            lua_createtable(L, 0, table.size());
            for (auto& [k, v] : table)
            {
                lua_pushlstring(L, k.data(), k.length());
                push_toml(L, v);
                lua_settable(L, -3);
            }
            break;
        }

        case toml::value_t::boolean: {
            auto const & boolean = value.as_boolean();
            lua_pushboolean(L, boolean);
            break;
        }

        case toml::value_t::floating: {
            auto const & floating = value.as_floating();
            lua_pushnumber(L, floating);
            break;
        }

        case toml::value_t::integer: {
            auto const & integer = value.as_integer();
            lua_pushinteger(L, integer);
            break;
        }

        case toml::value_t::string: {
            auto const & string = value.as_string();
            lua_pushlstring(L, string.data(), string.size());
            break;
        }

        default:
            throw std::runtime_error{"toml value not supported"};
    }
}

} // namespace

auto mytoml::l_parse_toml(lua_State* const L) -> int
{
    std::size_t len;
    auto const src = luaL_checklstring(L, 1, &len);
    try
    {
        push_toml(L, toml::parse_str(std::string {src, len}, toml::spec::v(1, 1, 0)));
        return 1;
    }
    catch (std::runtime_error const& err)
    {
        luaL_pushfail(L);
        lua_pushstring(L, err.what());
        return 2;
    }
}
