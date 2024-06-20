#include "applib.hpp"

#include "app.hpp"
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

#include <ncurses.h>

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
#include <csignal>
#include <cstring>
#include <ctime>
#include <functional>
#include <iostream>
#include <iterator>
#include <locale>

namespace { // lua support for app

using namespace std::literals::string_view_literals;

char logic_module;

auto l_pton(lua_State* const L) -> int
{
    auto const p = luaL_checkstring(L, 1);
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

auto l_raise(lua_State* const L) -> int
{
    auto const s = luaL_checkinteger(L, 1);
    if (0 != raise(s))
    {
        auto const e = errno;
        return luaL_error(L, "raise: %s", strerror(e));
    }
    return 0;
}

auto l_to_base64(lua_State* const L) -> int
{
    auto const input = check_string_view(L, 1);
    auto const outlen = mybase64::encoded_size(input.size());

    luaL_Buffer B;
    auto const output = luaL_buffinitsize(L, &B, outlen);
    mybase64::encode(input, output);
    luaL_pushresultsize(&B, outlen);

    return 1;
}

auto l_from_base64(lua_State* const L) -> int
{
    auto const input = check_string_view(L, 1);
    auto const outlen = mybase64::decoded_size(input.size());

    luaL_Buffer B;
    auto const output_first = luaL_buffinitsize(L, &B, outlen);
    auto const output_last = mybase64::decode(input, output_first);
    if (output_last)
    {
        luaL_pushresultsize(&B, std::distance(output_first, output_last));
        return 1;
    }
    else
    {
        return 0;
    }
}

auto l_setmodule(lua_State* const L) -> int
{
    lua_settop(L, 1);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &logic_module);
    return 0;
}

auto l_xor_strings(lua_State* const L) -> int
{
    auto const s1 = check_string_view(L, 1);
    auto const s2 = check_string_view(L, 2);

    if (s1.size() != s2.size())
    {
        return luaL_error(L, "xor_strings: length mismatch");
    }

    luaL_Buffer B;
    auto const output = luaL_buffinitsize(L, &B, s1.size());

    std::transform(std::begin(s1), std::end(s1), std::begin(s2), output, std::bit_xor());

    luaL_pushresultsize(&B, s1.size());
    return 1;
}

auto l_isalnum(lua_State* const L) -> int
{
    auto const i = luaL_checkinteger(L, 1);
    lua_pushboolean(L, isalnum(i));
    return 1;
}

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

auto l_shutdown(lua_State* const L) -> int
{
    App::from_lua(L)->shutdown();
    return 0;
}

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
        return 0;
    }
}

auto l_parse_irc_tags(lua_State* const L) -> int
{
    auto const buf = mutable_string_arg(L, 1);

    try
    {
        pushtags(L, parse_irc_tags(buf));
        return 1;
    }
    catch (irc_parse_error const& e)
    {
        return 0;
    }
}

auto l_parse_irc(lua_State* const L) -> int
{
    auto const buf = mutable_string_arg(L, 1);

    try
    {
        pushircmsg(L, parse_irc_message(buf));
        return 1;
    }
    catch (irc_parse_error const& e)
    {
        return 0;
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
    {"connect", l_start_irc},
    {"dnslookup", l_dnslookup},
    {"from_base64", l_from_base64},
    {"irccase", l_irccase},
    {"isalnum", l_isalnum},
    {"newtimer", l_new_timer},
    {"parse_irc_tags", l_parse_irc_tags},
    {"parse_irc", l_parse_irc},
    {"pton", l_pton},
    {"raise", l_raise},
    {"setmodule", l_setmodule},
    {"shutdown", l_shutdown},
    {"time", l_time},
    {"to_base64", l_to_base64},
    {"xor_strings", l_xor_strings},
    {"execute", l_execute},
    {"stop_input", l_stop_input},
    {"start_input", l_start_input},
    {"start_httpd", start_httpd},
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

    lua_callback(L, "print", 1);
    return 0;
}

} // end of lua support namespace

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

    luaL_requiref(L, "ncurses", luaopen_myncurses, 1);
    lua_pop(L, 1);

    luaL_requiref(L, "myopenssl", luaopen_myopenssl, 1);
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
    lua_pushcfunction(L, l_print);
    lua_setglobal(L, "print");

    /* populate arg */
    lua_createtable(L, argc - 2, 2);
    for (int i = 0; i < argc; i++)
    {
        push_string(L, argv[i]);
        lua_rawseti(L, -2, i - 1);
    }
    lua_setglobal(L, "arg");

    l_ncurses_resize(L);
}
