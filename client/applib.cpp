#include "applib.hpp"

#include "app.hpp"
#include "config.hpp"
#include "irc.hpp"
#include "lua_uv_dnslookup.hpp"
#include "lua_uv_timer.hpp"
#include "safecall.hpp"
#include "uv.hpp"

#include <ircmsg.hpp>
#include <mybase64.hpp>
#include <myncurses.h>

extern "C" {
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
}

#include <ncurses.h>

#ifdef LIBHS_FOUND
#include "hsfilter.hpp"
#endif

#include <algorithm>
#include <csignal>
#include <cstring>
#include <functional>
#include <iostream>
#include <iterator>
#include <locale>

namespace { // lua support for app

char logic_module;

auto lua_callback_worker(lua_State* const L) -> int
{
    auto const module_ty = lua_rawgetp(L, LUA_REGISTRYINDEX, &logic_module);
    if (module_ty != LUA_TNIL)
    {
        /* args key module */
        lua_insert(L, -2); /* args module key */
        lua_gettable(L, -2); /* args module cb */
        lua_remove(L, -2); /* args cb */
        lua_insert(L, 1); /* cb args */
        auto const args = lua_gettop(L) - 1;
        lua_call(L, args, 0);
    }
    return 0;
}

auto l_pton(lua_State* const L) -> int
{
    auto const p = luaL_checkstring(L, 1);
    bool ipv6 = strchr(p, ':');

    size_t len;
    int af;
    char buffer[16];

    if (ipv6) {
        af = AF_INET6;
        len = 16;
    } else {
        af = AF_INET;
        len = 4;
    }

    switch (inet_pton(af, p, buffer)) {
    case 1:
        lua_pushlstring(L, buffer, len);
        return 1;
    case 0:
        lua_pushnil(L);
        lua_pushstring(L, "pton: bad address");
        return 2;
    default: {
        auto const e = errno;
        lua_pushnil(L);
        lua_pushfstring(L, "pton: %s", strerror(e));
        return 2;
    }
    }
}

auto l_raise(lua_State* const L) -> int
{
    auto const s = luaL_checkinteger(L, 1);
    if (0 != raise(s)) {
        auto const e = errno;
        return luaL_error(L, "raise: %s", strerror(e));
    }
    return 0;
}

auto l_to_base64(lua_State* const L) -> int
{
    size_t input_len;
    auto const input = luaL_checklstring(L, 1, &input_len);
    auto const outlen = mybase64::encoded_size(input_len);

    luaL_Buffer B;
    auto const output = luaL_buffinitsize(L, &B, outlen);
    mybase64::encode({input, input_len}, output);
    luaL_pushresultsize(&B, outlen);

    return 1;
}

auto l_from_base64(lua_State* const L) -> int
{
    size_t input_len;
    auto const input = luaL_checklstring(L, 1, &input_len);
    auto const outlen = mybase64::decoded_size(input_len);

    luaL_Buffer B;
    auto const output = luaL_buffinitsize(L, &B, outlen);
    size_t len;
    if (mybase64::decode({input, input_len}, output, &len)) {
        luaL_pushresultsize(&B, len);
        return 1;
    } else {
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
    size_t l1, l2;
    auto const s1 = luaL_checklstring(L, 1, &l1);
    auto const s2 = luaL_checklstring(L, 2, &l2);

    if (l1 != l2) {
        return luaL_error(L, "xor_strings: length mismatch");
    }

    luaL_Buffer B;
    auto const output = luaL_buffinitsize(L, &B, l1);

    std::transform(s1, s1+l1, s2, output, std::bit_xor());

    luaL_pushresultsize(&B, l1);
    return 1;
}

auto l_isalnum(lua_State* const L) -> int
{
    auto const i = luaL_checkinteger(L, 1);
    lua_pushboolean(L, isalnum(i));
    return 1;
}

int l_irccase(lua_State* L) {
    char const* const charmap =
        "\x00\x01\x02\x03\x04\x05\x06\x07"
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

    size_t n;
    auto const str = luaL_checklstring(L, 1, &n);

    luaL_Buffer B;
    auto const output = luaL_buffinitsize(L, &B, n);
    std::transform(str, str+n, output, [charmap](char c) {
        return charmap[uint8_t(c)];
    });
    luaL_pushresultsize(&B, n);
    return 1;
}

auto l_newtimer(lua_State* const L) -> int
{
    auto const a = App::from_lua(L);
    push_new_uv_timer(L, &a->loop);
    return 1;
}

auto l_shutdown(lua_State* const L) -> int
{
    App::from_lua(L)->shutdown();
    return 0;
}

luaL_Reg const applib_module[] = {
    { "to_base64", l_to_base64 },
    { "from_base64", l_from_base64 },
    { "pton", l_pton },
    { "setmodule", l_setmodule },
    { "raise", l_raise },
    { "xor_strings", l_xor_strings },
    { "isalnum", l_isalnum },
    { "irccase", l_irccase },
    { "newtimer", l_newtimer},
    { "shutdown", l_shutdown},
    { "connect", start_irc },
    { "dnslookup", l_dnslookup },
    {}
};

auto l_print(lua_State* const L) -> int
{
    auto const n = lua_gettop(L);  /* number of arguments */

    luaL_Buffer b;
    luaL_buffinit(L, &b);

    for (int i = 1; i <= n; i++) {
            (void)luaL_tolstring(L, i, nullptr); // leaves string on stack
            luaL_addvalue(&b); // consumes string
            if (i<n) luaL_addchar(&b, '\t');
    }

    luaL_pushresult(&b);
    lua_replace(L, 1);
    lua_settop(L, 1);

    lua_callback(L, "print");
    return 0;
}

} // end of lua support namespace


auto load_logic(lua_State* const L, char const* const filename) -> bool
{
    auto const r = luaL_loadfile(L, filename);
    if (LUA_OK == r) {
        safecall(L, "load_logic", 0);
        return true;
    } else {
        auto const err = lua_tolstring(L, -1, nullptr);
        endwin();
        std::cerr << "error in load_logic:load: " << err << std::endl;
        lua_pop(L, 1);
        return false;
    }
}

auto lua_callback(lua_State* const L, char const* const key) -> void
{
    /* args */
    lua_pushcfunction(L, lua_callback_worker); /* args f */
    lua_insert(L, 1); /* f args */
    lua_pushstring(L, key); /* f args key */
    safecall(L, key, lua_gettop(L) - 1);
}

auto prepare_globals(lua_State* const L, int const argc, char ** const argv) -> void
{
    /* setup libraries */
    luaL_openlibs(L);
    luaL_requiref(L, "ncurses", luaopen_myncurses, 1);
    lua_pop(L, 1);

#ifdef LIBHS_FOUND
    luaL_requiref(L, "hsfilter", luaopen_hsfilter, 1);
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
    for (int i = 0; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i-1);
    }
    lua_setglobal(L, "arg");

    l_ncurses_resize(L);
}
