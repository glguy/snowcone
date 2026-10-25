#include "to_toml.hpp"
#include "toml.hpp"

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <cstdio>
#include <cstdlib>
#include <limits>
#include <stdexcept>
#include <string>
#include <string_view>

namespace {

/// Deeper nesting is rejected; this also stops self-referencing tables.
constexpr int max_depth = 100;

/// The fewest significant digits that read back as the same double, so 0.1
/// stays "0.1". toml11's default is the stream's 6, which loses precision.
auto float_format(double const x) -> toml::floating_format_info
{
    auto prec = std::numeric_limits<double>::digits10;
    for (; prec < std::numeric_limits<double>::max_digits10; ++prec)
    {
        char buf[32];
        std::snprintf(buf, sizeof buf, "%.*g", prec, x);
        if (std::strtod(buf, nullptr) == x)
        {
            break;
        }
    }
    return {toml::floating_format::defaultfloat, static_cast<std::size_t>(prec)};
}

auto export_value(lua_State* const L, int depth) -> toml::value;

auto export_table(lua_State* const L, int const depth) -> toml::value
{
    // Each level of nesting holds a table, a key and a value on the stack
    if (depth > max_depth or not lua_checkstack(L, 3))
    {
        throw std::runtime_error{"table nesting too deep"};
    }

    lua_pushnil(L);
    if (0 == lua_next(L, -2))
    {
        return toml::table{};
    }
    else if (lua_isinteger(L, -2))
    {
        lua_Integer entries = 0;
        lua_Integer max_key = 0;

        // Determine array size
        do {
            // lua_next returns key and value; discard the value
            lua_pop(L, 1);
            
            // Ensure the value is actually an integer and not just convertible to one
            if (not lua_isinteger(L, -1)) throw std::runtime_error{"bad array index type"};
            
            // Array indexes must be positive integers
            auto const i = lua_tointeger(L, -1);
            if (i < 1) throw std::runtime_error{"non-positive array index"};
            
            // Remember largest key seen so we can detect gaps
            if (i > max_key) max_key = i;
            ++entries;
        } while (0 != lua_next(L, -2));

        if (entries != max_key) throw std::runtime_error{"incomplete array"};

        toml::array a;
        a.reserve(entries);
        for (lua_Integer i = 1; i <= entries; ++i)
        {
            lua_rawgeti(L, -1, i); // raw: a metamethod could raise past C++ objects
            a.push_back(export_value(L, depth + 1));
        }
        return toml::value{std::move(a)};
    }
    else
    {
        toml::table t;

        do
        {
            // Not lua_isstring: converting a number key in place breaks lua_next
            if (lua_type(L, -2) != LUA_TSTRING) throw std::runtime_error{"non-string table key"};

            std::size_t len;
            auto const str = lua_tolstring(L, -2, &len);
            t.emplace(std::string{str, len}, export_value(L, depth + 1));
        }
        while (0 != lua_next(L, -2));

        return toml::value{std::move(t)};
    }
}

auto export_value(lua_State* const L, int const depth) -> toml::value
{
    toml::value result;

    switch (lua_type(L, -1))
    {
    case LUA_TBOOLEAN: {
        // lua_toboolean returns int, which would make a TOML integer
        result = toml::value{lua_toboolean(L, -1) != 0};
        break;
    }

    case LUA_TNUMBER:
        if (lua_isinteger(L, -1))
        {
            result = toml::value{lua_tointeger(L, -1)};
        }
        else
        {
            auto const x = lua_tonumber(L, -1);
            result = toml::value{x, float_format(x)};
        }
        break;

    case LUA_TSTRING: {
        std::size_t len;
        auto const str = lua_tolstring(L, -1, &len);
        result = toml::value{std::string{str, len}};
        break;
    }

    case LUA_TTABLE:
        result = export_table(L, depth);
        break;

    default:
        throw std::runtime_error{"unsupported value type"};
    }

    lua_pop(L, 1);
    return result;
}

} // namespace

auto mytoml::l_to_toml(lua_State* const L) -> int
{
    lua_settop(L, 1);
    try
    {
        auto const value{export_value(L, 0)};
        auto const output{toml::format(value, toml::spec::v(1, 1, 0))};
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
