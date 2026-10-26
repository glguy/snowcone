#include "applib.hpp"

#include "app.hpp"
#include "boundary.hpp"
#include "config.hpp"
#include "dnslookup.hpp"
#include "httpd.hpp"
#include "irc/lua.hpp"
#include "safecall.hpp"
#include "strings.hpp"
#include "timer.hpp"

#include <ircmsg.hpp>
#include <mybase64.hpp>
#include <myncurses.h>
#include <myopenssl.hpp>
#include <mytoml.hpp>

extern "C" {
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
}

#ifdef LIBHS_FOUND
#include "hsfilter.hpp"
#endif

#ifdef LIBIDN_FOUND
#include "mystringprep.h"
#endif

#ifdef LIBARCHIVE_FOUND
#include "myarchive.h"
#endif

#include "process.hpp"

#include <algorithm>
#include <chrono>
#include <climits>
#include <cstdio>
#include <csignal>
#include <cstring>
#include <ctime>
#include <iterator>

namespace { // lua support for app

using namespace std::literals::string_view_literals;

char logic_module;

/**
 * @brief Lua binding for inet_pton.
 *
 * Converts an IP address string (argument 1) from presentation to network format.
 * It detects IPv6 if a colon (':') is present; otherwise, it treats the address as IPv4.
 * On success, it pushes the binary address on the Lua stack.
 * On failure, it pushes a failure indicator and an error message.
 *
 * param:     string txt presentation-format address
 * return[1]: string network-format address
 * return[2]: nil    failure indicator
 * return[2]: string error message
 *
 * @param L Lua state
 * @return int 1 on success; 2 on error
 */
auto l_pton(lua_State* const L) -> int
{
    auto const p = check_c_string(L, 1).data();
    bool const ipv6 = strchr(p, ':');

    size_t len;
    int af;
    char buffer[16];

    if (ipv6)
    {
        af = AF_INET6;
        len = 16;
    }
    else
    {
        af = AF_INET;
        len = 4;
    }

    switch (inet_pton(af, p, buffer))
    {
    case 1:
        lua_pushlstring(L, buffer, len);
        return 1;
    case 0:
        luaL_pushfail(L);
        push_string(L, "pton: bad address"sv);
        return 2;
    default: {
        auto const e = errno;
        luaL_pushfail(L);
        lua_pushfstring(L, "pton: %s", strerror(e));
        return 2;
    }
    }
}

/**
 * @brief Lua binding for raise – send a signal to the current thread.
 *
 * Sends the specified signal (argument 1) to the current thread using the standard C raise() function.
 * On failure, raises a Lua error with the string representation of errno.
 *
 * param:     integer sig  signal number to send
 * error:     raises a Lua error with the error message on failure
 *
 * @param L Lua state
 * @return int 0 on success; raises Lua error on failure
 */
auto l_raise(lua_State* const L) -> int
{
    auto const s = luaL_checkinteger(L, 1);
    luaL_argcheck(L, 0 <= s && s < NSIG, 1, "invalid signal number");
    if (0 != raise(static_cast<int>(s)))
    {
        auto const e = errno;
        return luaL_error(L, "raise: %s", strerror(e));
    }
    return 0;
}

auto l_setmodule(lua_State* const L) -> int
{
    lua_settop(L, 1);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &logic_module);
    return 0;
}

/**
 * @brief Lua binding for isalnum(3)
 *
 * Checks if the given integer value corresponds to an alphanumeric character (A-Z, a-z, 0-9).
 * Values outside 0..255 (Unicode code points, for example) are never alphanumeric here;
 * isalnum(3) is undefined for them.
 *
 * param: integer c integer value of the character
 * return: boolean true for alphanumeric input
 *
 * @param L Lua state
 * @return int 1
 */
auto l_isalnum(lua_State* const L) -> int
{
    auto const i = luaL_checkinteger(L, 1);
    lua_pushboolean(L, 0 <= i && i <= UCHAR_MAX && isalnum(static_cast<int>(i)));
    return 1;
}

/**
 * @brief Lua binding for RFC 1459 case mapping.
 *
 * Converts the input string to its uppercase form according to RFC 1459 rules,
 * which are used for case-insensitive comparisons in IRC. In addition to ASCII
 * uppercase conversion, '{', '}', '|' and '~' map to '[', ']', '\\' and '^'
 * respectively.
 *
 * param:   string input text to normalize
 * return:  string IRC case normalized text
 *
 * @param L Lua state
 * @return int 1
 */
auto l_irccase(lua_State* const L) -> int
{
    char const* const charmap = "\x00\x01\x02\x03\x04\x05\x06\x07"
                                "\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f"
                                "\x10\x11\x12\x13\x14\x15\x16\x17"
                                "\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f"
                                " !\"#$%&'()*+,-./0123456789:;<=>?"
                                "@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_"
                                "`ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^\x7f"
                                "\x80\x81\x82\x83\x84\x85\x86\x87"
                                "\x88\x89\x8a\x8b\x8c\x8d\x8e\x8f"
                                "\x90\x91\x92\x93\x94\x95\x96\x97"
                                "\x98\x99\x9a\x9b\x9c\x9d\x9e\x9f"
                                "\xa0\xa1\xa2\xa3\xa4\xa5\xa6\xa7"
                                "\xa8\xa9\xaa\xab\xac\xad\xae\xaf"
                                "\xb0\xb1\xb2\xb3\xb4\xb5\xb6\xb7"
                                "\xb8\xb9\xba\xbb\xbc\xbd\xbe\xbf"
                                "\xc0\xc1\xc2\xc3\xc4\xc5\xc6\xc7"
                                "\xc8\xc9\xca\xcb\xcc\xcd\xce\xcf"
                                "\xd0\xd1\xd2\xd3\xd4\xd5\xd6\xd7"
                                "\xd8\xd9\xda\xdb\xdc\xdd\xde\xdf"
                                "\xe0\xe1\xe2\xe3\xe4\xe5\xe6\xe7"
                                "\xe8\xe9\xea\xeb\xec\xed\xee\xef"
                                "\xf0\xf1\xf2\xf3\xf4\xf5\xf6\xf7"
                                "\xf8\xf9\xfa\xfb\xfc\xfd\xfe\xff";

    auto const str = check_string_view(L, 1);

    luaL_Buffer B;
    auto const output = luaL_buffinitsize(L, &B, str.size());
    std::transform(std::begin(str), std::end(str), output, [charmap](char c) {
        return charmap[uint8_t(c)];
    });
    luaL_pushresultsize(&B, str.size());
    return 1;
}

/**
 * @brief Initiate the shutdown process for the client.
 *
 * This will tear down the signal and stdin handlers for the process.
 *
 * @param L Lua state
 * @return int 0
 */
auto l_shutdown(lua_State* const L) -> int
{
    App::from_lua(L)->shutdown();
    return 0;
}

/**
 * @brief Seconds on a monotonic clock
 *
 * The clock only moves forward and isn't changed by setting the system
 * time, so differences between readings are durations. Its zero is
 * arbitrary.
 *
 * return: number seconds, with fractions
 *
 * @param L Lua state
 * @return int 1
 */
auto l_monotime(lua_State* const L) -> int
{
    using namespace std::chrono;
    auto const now = duration<lua_Number>{steady_clock::now().time_since_epoch()};
    lua_pushnumber(L, now.count());
    return 1;
}

/**
 * @brief Lua binding for timespec_get(3)
 *
 * Gets the seconds and nanoseconds since the 1970 epoch.
 *
 * return: integer seconds
 * return: integer nanoseconds
 * raise:  error on failure
 *
 * @param L Lua state
 * @return int 2 on success; raises Lua error on failure
 */
auto l_time(lua_State* const L) -> int
{
    timespec now;
    if (TIME_UTC == timespec_get(&now, TIME_UTC))
    {
        lua_pushinteger(L, now.tv_sec);
        lua_pushinteger(L, now.tv_nsec);
        return 2;
    }
    else
    {
        return luaL_error(L, "timespec_get: failed");
    }
}

/**
 * @brief Parses a string using IRC tags format.
 *
 * IRC tags are key-value pairs separated by ';'. Each key is optionally
 * followed by a value. The value is delimited with an '='. Escaped characters
 * in the value position are unescaped. Omitted values are treated as empty
 * string values.
 *
 * Example: key1=value1;key2=value2
 *
 * param:       string input Tag input string
 * return[1]:   table key/value pairs
 * return[2]:   nil failure indicator
 * return[2]:   string failure reason
 *
 * @param L Lua state
 * @return int 1 on success; 2 on failure
 */
auto l_parse_irc_tags(lua_State* const L) -> int
{
    // The parser works on a NUL-terminated copy, so a NUL would end the line
    auto const txt = check_c_string(L, 1);

    try
    {
        luaL_Buffer B;
        auto const buf = luaL_buffinitsize(L, &B, txt.size() + 1);
        std::memcpy(buf, txt.data(), txt.size() + 1);
        pushtags(L, parse_irc_tags(buf));
        return 1;
    }
    catch (irc_parse_error const& e)
    {
        luaL_pushfail(L);
        lua_pushstring(L, e.what());
        return 2;
    }
}

/**
 * @brief Parses one IRC message line, without its CR LF terminator.
 *
 * The parsed message has the following keys:
 * - "tags": a required, potentially empty table of the key-value pairs of the tags of the message
 * - "source": an optional field containing the source of the message
 * - "command": a required field containing the string name or integer numeric of the command
 * - [1..]: arguments of the command are stored in integer fields starting a 1
 * 
 * param:       string input IRC message line
 * return[1]:   table IRC message
 * return[2]:   nil failure indicator
 * return[2]:   string failure reason
 *
 * @param L Lua state
 * @return int 1 on success; 2 on failure
 */
auto l_parse_irc(lua_State* const L) -> int
{
    // The parser works on a NUL-terminated copy, so a NUL would end the line
    auto const txt = check_c_string(L, 1);
    try
    {
        luaL_Buffer B;
        auto const buf = luaL_buffinitsize(L, &B, txt.size() + 1);
        std::memcpy(buf, txt.data(), txt.size() + 1);
        pushircmsg(L, parse_irc_message(buf));
        return 1;
    }
    catch (irc_parse_error const& e)
    {
        luaL_pushfail(L);
        lua_pushstring(L, e.what());
        return 2;
    }
}

auto l_start_input(lua_State* const L) -> int
{
    App::from_lua(L)->start_input();
    return 0;
}

auto l_stop_input(lua_State* const L) -> int
{
    App::from_lua(L)->stop_input();
    return 0;
}

luaL_Reg const applib_module[] = {
    {"connect", boundary<l_start_irc>},
    {"dnslookup", boundary<l_dnslookup>},
    {"irccase", boundary<l_irccase>},
    {"isalnum", boundary<l_isalnum>},
    {"newtimer", boundary<l_new_timer>},
    {"parse_irc_tags", boundary<l_parse_irc_tags>},
    {"parse_irc", boundary<l_parse_irc>},
    {"pton", boundary<l_pton>},
    {"raise", boundary<l_raise>},
    {"setmodule", boundary<l_setmodule>},
    {"shutdown", boundary<l_shutdown>},
    {"time", boundary<l_time>},
    {"monotime", boundary<l_monotime>},
    {"execute", boundary<l_execute>},
    {"stop_input", boundary<l_stop_input>},
    {"start_input", boundary<l_start_input>},
    {"start_httpd", boundary<start_httpd>},
    {}
};

auto l_print(lua_State* const L) -> int
{
    auto const n = lua_gettop(L); /* number of arguments */

    luaL_Buffer b;
    luaL_buffinit(L, &b);

    for (int i = 1; i <= n; i++)
    {
        (void)luaL_tolstring(L, i, nullptr); // leaves string on stack
        luaL_addvalue(&b); // consumes string
        if (i < n)
            luaL_addchar(&b, '\t');
    }

    luaL_pushresult(&b);
    lua_replace(L, 1);
    lua_settop(L, 1);

    if (App::from_lua(L)->is_headless())
    {
        std::size_t len;
        auto const str = lua_tolstring(L, 1, &len);
        std::fwrite(str, 1, len, stdout);
        std::fputc('\n', stdout);
        std::fflush(stdout);
        return 0;
    }

    lua_callback(L, "print", 1);
    return 0;
}

} // end of lua support namespace

/**
 * @brief Invoke the logic callback hook from the logic module.
 * 
 * @param L Lua state
 * @param key name of callback; passed as first function argument to the callback
 * @param args number of arguments on the stack to use a function arguments
 * @return true on successful call
 * @return false on callback failure or no callback found
 */
auto lua_callback(lua_State* const L, char const* const key, int args) -> bool
{
    auto const module_ty = lua_rawgetp(L, LUA_REGISTRYINDEX, &logic_module);
    if (module_ty != LUA_TNIL)
    {
        push_string(L, key);
        lua_rotate(L, -(args + 2), 2);
        return LUA_OK == safecall(L, key, args + 1);
    }
    else
    {
        lua_pop(L, args + 1);
        return false;
    }
}

auto prepare_globals(lua_State* const L, int const argc, char const* const* const argv) -> void
{
    /* setup libraries */
    luaL_openlibs(L);

    auto const headless = App::from_lua(L)->is_headless();

    // There is no screen to draw on in script mode
    if (not headless)
    {
        luaL_requiref(L, "ncurses", luaopen_myncurses, 1);
        lua_pop(L, 1);
    }

    luaL_requiref(L, "myopenssl", luaopen_myopenssl, 1);
    lua_pop(L, 1);

    luaL_requiref(L, "mybase64", luaopen_mybase64, 1);
    lua_pop(L, 1);

    luaL_requiref(L, "mytoml", luaopen_mytoml, 1);
    lua_pop(L, 1);

#ifdef LIBHS_FOUND
    luaL_requiref(L, "hsfilter", luaopen_hsfilter, 1);
    lua_pop(L, 1);
#endif

#ifdef LIBIDN_FOUND
    luaL_requiref(L, "mystringprep", luaopen_mystringprep, 1);
    lua_pop(L, 1);
#endif

#ifdef LIBARCHIVE_FOUND
    luaL_requiref(L, "myarchive", luaopen_myarchive, 1);
    lua_pop(L, 1);
#endif

    luaL_newlib(L, applib_module);
    lua_pushinteger(L, SIGINT);
    lua_setfield(L, -2, "SIGINT");
    lua_pushinteger(L, SIGTSTP);
    lua_setfield(L, -2, "SIGTSTP");
    lua_setglobal(L, "snowcone");

    /* Overwrite the lualib print with the custom one */
    lua_pushcfunction(L, boundary<l_print>);
    lua_setglobal(L, "print");

    /* populate arg */
    lua_createtable(L, argc - 2, 2);
    for (int i = 0; i < argc; i++)
    {
        push_string(L, argv[i]);
        lua_rawseti(L, -2, i - 1);
    }
    lua_setglobal(L, "arg");

    if (not headless)
    {
        l_ncurses_resize(L);
    }
}
