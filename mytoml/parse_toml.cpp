/**
 * @file parse_toml.cpp
 * @brief parse_toml: TOML text to Lua values, with error messages that
 * give positions but not the text of the file
 *
 */
#include "parse_toml.hpp"
#include "toml.hpp"

#include <algorithm>
#include <cstddef>
#include <cstdio>
#include <exception>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

namespace {

// An error message lists this many problems at most, then counts the rest;
// the later ones are usually consequences of the first.
constexpr std::size_t max_reported_errors = 5;

/// "line L, column C" for the start of location, both counted from 1
auto position(toml::source_location const& location) -> std::string
{
    return "line " + std::to_string(location.first_line_number())
        + ", column " + std::to_string(location.first_column_number());
}

/// Drop the leading "toml::function:" from an error title, if present:
/// "toml::parse_array: missing bracket" becomes "missing bracket"
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

/// One error as a single line: its first position and title, then each
/// position with its note. Only positions and the library's own words:
/// toml::format_error would quote the source line, and configuration files
/// can hold secrets.
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

/// All errors, one per line, skipping a line that repeats the one before.
/// After max_reported_errors lines, the rest are counted: "and N more".
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

/// Push value converted to Lua (see l_parse_toml). Returns null, or the
/// value it couldn't convert: a date or time, or a table or array nested
/// past the room on the Lua stack. Values pushed before are left on the
/// stack. Nothing here needs destroying, so a Lua error can unwind it.
auto push_toml(lua_State* const L, toml::value const& value) -> toml::value const*
{
    // Each level of nesting holds its table, and for a TOML table the key
    // being set, on the stack
    if (not lua_checkstack(L, 3))
    {
        return &value;
    }

    switch (value.type()) {
        case toml::value_t::array: {
            auto const & array = value.as_array();
            lua_createtable(L, array.size(), 0);
            lua_Integer i = 1;
            for (auto& x : array)
            {
                if (auto const unconverted = push_toml(L, x))
                {
                    return unconverted;
                }
                lua_rawseti(L, -2, i++);
            }
            return nullptr;
        }

        case toml::value_t::table: {
            auto const & table = value.as_table();
            lua_createtable(L, 0, table.size());
            for (auto& [k, v] : table)
            {
                lua_pushlstring(L, k.data(), k.length());
                if (auto const unconverted = push_toml(L, v))
                {
                    return unconverted;
                }
                lua_settable(L, -3);
            }
            return nullptr;
        }

        case toml::value_t::boolean:
            lua_pushboolean(L, value.as_boolean());
            return nullptr;

        case toml::value_t::floating:
            lua_pushnumber(L, value.as_floating());
            return nullptr;

        case toml::value_t::integer:
            lua_pushinteger(L, value.as_integer());
            return nullptr;

        case toml::value_t::string: {
            auto const & string = value.as_string();
            lua_pushlstring(L, string.data(), string.size());
            return nullptr;
        }

        default:
            return &value;
    }
}

/// Why push_toml couldn't convert value
auto unconverted_message(toml::value const& value) -> std::string
{
    if (value.is_array() || value.is_table())
    {
        return "toml nesting too deep";
    }
    return position(value.location()) + ": " + toml::to_string(value.type()) + " values are not supported";
}

/// A document to convert, and what of it push_toml couldn't convert
struct Conversion
{
    toml::value const* document;
    toml::value const* unconverted;
};

/// Lua function: convert the Conversion that the light userdata at 1
/// points to, and return the value. l_parse_toml runs it in protected mode,
/// so a memory error can't skip the destructors of the C++ objects it holds.
auto convert(lua_State* const L) -> int
{
    auto& conversion = *static_cast<Conversion*>(lua_touserdata(L, 1));
    conversion.unconverted = push_toml(L, *conversion.document);
    return 1;
}

} // namespace

auto mytoml::l_parse_toml(lua_State* const L) -> int
{
    std::size_t len;
    auto const src = luaL_checklstring(L, 1, &len);

    // Lua calls that can raise come after every C++ object here is gone,
    // or run in protected mode: the error message is copied out to push
    char message[2048];
    auto const set_message = [&message](std::string const& text) {
        std::snprintf(message, sizeof message, "%s", text.c_str());
    };
    auto status = LUA_OK;
    try
    {
        auto const result = toml::try_parse(
            std::vector<unsigned char>(src, src + len), "", toml::spec::v(1, 1, 0));
        if (result.is_err())
        {
            set_message(describe(result.as_err()));
        }
        else
        {
            Conversion conversion{&result.as_ok(), nullptr};
            lua_pushcfunction(L, convert);
            lua_pushlightuserdata(L, &conversion);
            status = lua_pcall(L, 1, 1, 0);
            if (status == LUA_OK)
            {
                if (nullptr == conversion.unconverted)
                {
                    return 1;
                }
                lua_pop(L, 1); // what was converted
                set_message(unconverted_message(*conversion.unconverted));
            }
        }
    }
    catch (std::exception const& err)
    {
        set_message(err.what());
    }

    if (status != LUA_OK)
    {
        return lua_error(L); // the conversion's error, on top
    }
    luaL_pushfail(L);
    lua_pushstring(L, message);
    return 2;
}
