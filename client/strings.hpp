#pragma once
/**
 * @file strings.hpp
 * @brief Moving strings between C++ and Lua.
 *
 * Read strings out of Lua through these helpers, with their length, rather
 * than as `char const*`, so an embedded NUL can't silently truncate them.
 * - check_string_view for data that may hold any bytes (IRC lines, bodies).
 * - check_c_string for strings handed to C APIs that stop at the first NUL
 *   (hostnames, paths, executables, OpenSSL names). It rejects a NUL.
 * - to_string_view and has_nul to read a value that is already on the stack,
 *   such as a table field, without raising.
 * Messages that are only displayed may still use lua_tostring.
 */

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include <cstddef>
#include <optional>
#include <string_view>

/**
 * @brief Push string_view value onto Lua stack
 *
 * @param L Lua
 * @param str string
 * @return char const* string in Lua memory
 */
inline auto push_string(lua_State* const L, std::string_view const str) -> char const*
{
    return lua_pushlstring(L, std::data(str), std::size(str));
}

/**
 * @brief The string argument at arg, which may contain any bytes. Numbers
 * are converted, as luaL_checklstring does.
 */
inline auto check_string_view(lua_State* L, int const arg) -> std::string_view
{
    std::size_t len;
    auto const str = luaL_checklstring(L, arg, &len);
    return {str, len};
}

/**
 * @brief Like check_string_view, but nil or absent gives nullopt
 */
inline auto opt_string_view(lua_State* L, int const arg) -> std::optional<std::string_view>
{
    if (lua_isnoneornil(L, arg))
    {
        return std::nullopt;
    }
    return check_string_view(L, arg);
}

/**
 * @brief Whether str contains a NUL byte, which a C API would take as its end
 */
inline auto has_nul(std::string_view const str) -> bool
{
    return str.find('\0') != std::string_view::npos;
}

/**
 * @brief The string argument at arg, for a C API. Raises an argument error
 * if it contains a NUL byte. The result is NUL-terminated at its size.
 */
inline auto check_c_string(lua_State* L, int const arg) -> std::string_view
{
    auto const str = check_string_view(L, arg);
    luaL_argcheck(L, not has_nul(str), arg, "contains a NUL byte");
    return str;
}

/**
 * @brief The string at idx, or nullopt if the value there isn't a string.
 * Never raises, and never converts a number (lua_tolstring converts in
 * place, which would break a lua_next traversal).
 */
inline auto to_string_view(lua_State* L, int const idx) -> std::optional<std::string_view>
{
    if (lua_type(L, idx) != LUA_TSTRING)
    {
        return std::nullopt;
    }
    std::size_t len;
    auto const str = lua_tolstring(L, idx, &len);
    return std::string_view{str, len};
}
