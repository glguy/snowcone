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
#include <cstdio>
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

/**
 * @brief Write text that may hold untrusted data (an error message quoting
 * a server's line, say) to a terminal, so it can't send control sequences.
 * Newlines and tabs pass, as do printable ASCII and valid UTF-8 other than
 * the C1 controls (U+0080 to U+009F, which some terminals obey). Any other
 * byte is written as \xNN. Nothing is allocated, so the panic handler can
 * use it.
 */
inline auto write_escaped(std::FILE* const out, std::string_view const str) -> void
{
    auto const is_cont = [&](std::size_t const i) {
        return i < str.size() && (static_cast<unsigned char>(str[i]) & 0xc0) == 0x80;
    };

    for (std::size_t i = 0; i < str.size();)
    {
        auto const c = static_cast<unsigned char>(str[i]);
        std::size_t len = 0; // of a sequence to copy, or 0 to escape c
        if (c == '\n' || c == '\t' || (0x20 <= c && c < 0x7f))
        {
            len = 1;
        }
        else if (0xc2 <= c && c <= 0xf4)
        {
            auto const n = c < 0xe0 ? 2u : c < 0xf0 ? 3u : 4u;
            auto valid = true;
            for (std::size_t k = 1; k < n; ++k)
            {
                valid = valid && is_cont(i + k);
            }
            auto const c1 = c == 0xc2 && valid && static_cast<unsigned char>(str[i + 1]) < 0xa0;
            if (valid && not c1)
            {
                len = n;
            }
        }

        if (len > 0)
        {
            std::fwrite(str.data() + i, 1, len, out);
            i += len;
        }
        else
        {
            std::fprintf(out, "\\x%02x", c);
            ++i;
        }
    }
}
