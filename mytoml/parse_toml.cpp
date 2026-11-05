#include "parse_toml.hpp"
#include "toml.hpp"

#include <algorithm>
#include <cstddef>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

namespace {

// A syntax error reports this many problems at most; the later ones are
// usually consequences of the first.
constexpr std::size_t max_reported_errors = 5;

auto position(toml::source_location const& location) -> std::string
{
    return "line " + std::to_string(location.first_line_number())
        + ", column " + std::to_string(location.first_column_number());
}

// "toml::parse_array: missing bracket" becomes "missing bracket"
auto strip_function_name(std::string_view title) -> std::string_view
{
    if (title.starts_with("toml::")) {
        auto const colon = title.find(':', 6);
        if (colon != title.npos) {
            title.remove_prefix(colon + 1);
            title.remove_prefix(std::min(title.find_first_not_of(' '), title.size()));
        }
    }
    return title;
}

// Only positions and the library's own words: toml::format_error would quote
// the source line, and configuration files can hold secrets.
auto describe(toml::error_info const& error) -> std::string
{
    std::string result;
    auto const title = strip_function_name(error.title());
    bool first = true;
    for (auto const& [location, note] : error.locations())
    {
        if (first) {
            result += position(location) + ": ";
            result += title;
            first = false;
        } else {
            result += "; " + position(location);
        }
        // one note spells out CR LF, which would break up the line
        auto const printable = std::ranges::none_of(
            note, [](unsigned char const c) { return c < 0x20; });
        if (printable && note != "here") {
            result += " (" + note + ")";
        }
    }
    return result;
}

auto describe(std::vector<toml::error_info> const& errors) -> std::string
{
    std::string result;
    std::string previous;
    std::size_t reported = 0;
    std::size_t more = 0;
    for (auto const& error : errors)
    {
        // recovery can report one mistake at several levels of nesting
        auto line = describe(error);
        if (line == previous) { continue; }

        if (reported == max_reported_errors) {
            ++more;
        } else {
            if (reported > 0) { result += '\n'; }
            result += line;
            ++reported;
        }
        previous = std::move(line);
    }
    if (more > 0) {
        result += "\nand " + std::to_string(more) + " more";
    }
    return result;
}

auto push_toml(lua_State* const L, toml::value const& value) -> void
{
    // Each level of nesting holds a table and a key on the stack
    if (not lua_checkstack(L, 3))
    {
        throw std::runtime_error{"toml nesting too deep"};
    }

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
            throw std::runtime_error{
                position(value.location()) + ": " + toml::to_string(value.type()) + " values are not supported"};
    }
}

} // namespace

auto mytoml::l_parse_toml(lua_State* const L) -> int
{
    std::size_t len;
    auto const src = luaL_checklstring(L, 1, &len);
    try
    {
        auto const result = toml::try_parse(
            std::vector<unsigned char>(src, src + len), "", toml::spec::v(1, 1, 0));
        if (result.is_err())
        {
            throw std::runtime_error{describe(result.as_err())};
        }
        push_toml(L, result.as_ok());
        return 1;
    }
    catch (std::exception const& err)
    {
        luaL_pushfail(L);
        lua_pushstring(L, err.what());
        return 2;
    }
}
