#include "applib.hpp"
#include "config.hpp"

#include "app.hpp"
#include "configuration.hpp"
#include "lua_uv_dnslookup.hpp"
#include "lua_uv_filewatcher.hpp"
#include "lua_uv_timer.hpp"
#include "safecall.hpp"
#include "uv.hpp"

#include <myncurses.h>
#include <ircmsg.hpp>

#ifdef GEOIP_FOUND
#include <mygeoip.h>
#endif
#include <mybase64.hpp>

extern "C" {
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
}

#include <ncurses.h>

#include <algorithm>
#include <charconv>
#include <cstring>
#include <functional>
#include <iostream>
#include <iterator>
#include <locale>

namespace { // lua support for app

char logic_module;

/**
 * @brief Push string_view value onto Lua stack
 * 
 * @param L Lua
 * @param str string
 * @return char const* string in Lua memory 
 */
char const* push_stringview(lua_State* L, std::string_view str) {
    return lua_pushlstring(L, str.data(), str.size());
}

int lua_callback_worker(lua_State* L)
{
    int module_ty = lua_rawgetp(L, LUA_REGISTRYINDEX, &logic_module);
    if (module_ty != LUA_TNIL)
    {
        /* args key module */
        lua_insert(L, -2); /* args module key */
        lua_gettable(L, -2); /* args module cb */
        lua_remove(L, -2); /* args cb */
        lua_insert(L, 1); /* cb args */ 
        int args = lua_gettop(L) - 1;
        lua_call(L, args, 0);
    }
    return 0;
}

int l_pton(lua_State* L)
{
    char const* p = luaL_checkstring(L, 1);
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
        int e = errno;
        lua_pushnil(L);
        lua_pushfstring(L, "pton: %s", strerror(e));
        return 2;
    }
    }
}

int l_raise(lua_State* L)
{
    lua_Integer s = luaL_checkinteger(L, 1);
    if (0 != raise(s)) {
        int e = errno;
        return luaL_error(L, "raise: %s", strerror(e));
    }
    return 0;
}

int l_to_base64(lua_State* L)
{
    size_t input_len;
    char const* input = luaL_checklstring(L, 1, &input_len);
    size_t outlen = (input_len + 2) / 3 * 4;
    
    luaL_Buffer B;
    auto output = luaL_buffinitsize(L, &B, outlen);
    mybase64::encode({input, input_len}, output);
    luaL_pushresultsize(&B, outlen);

    return 1;
}

int l_from_base64(lua_State* L)
{
    size_t input_len;
    char const* input = luaL_checklstring(L, 1, &input_len);
    size_t outlen = (input_len + 3) / 4 * 3;
    
    luaL_Buffer B;
    auto output = luaL_buffinitsize(L, &B, outlen);
    size_t len;
    if (mybase64::decode({input, input_len}, output, &len)) {
        luaL_pushresultsize(&B, len);
    } else {
        lua_pushnil(L);
    }
    return 1;
}

int l_send_irc(lua_State* L)
{
    auto const a = app::from_lua(L);

    size_t len;
    auto const cmd = luaL_optlstring(L, 1, nullptr, &len);
    bool result;

    if (cmd == nullptr) {
        result = a->close_irc();
    } else {
        lua_settop(L, 1);
        auto const ref = luaL_ref(L, LUA_REGISTRYINDEX);
        result = a->send_irc(cmd, len, ref);
    }

    if (!result) {
        return luaL_error(L, "IRC not connected");
    }    

    return 0;
}

int l_shutdown(lua_State* L)
{
    app::from_lua(L)->shutdown();
    return 0;
}

int l_setmodule(lua_State* L)
{
    lua_rawsetp(L, LUA_REGISTRYINDEX, &logic_module);
    return 0;
}

int l_newtimer(lua_State* L)
{
    auto const a = app::from_lua(L);
    push_new_uv_timer(L, &a->loop);
    return 1;
}

int l_newwatcher(lua_State* L)
{
    auto const a = app::from_lua(L);
    push_new_fs_event(L, &a->loop);
    return 1;
}

int l_xor_strings(lua_State* L)
{
    size_t l1, l2;
    char const* s1 = luaL_checklstring(L, 1, &l1);
    char const* s2 = luaL_checklstring(L, 2, &l2);

    if (l1 != l2) {
        return luaL_error(L, "xor_strings: length mismatch");
    }

    luaL_Buffer B;
    char *output = luaL_buffinitsize(L, &B, l1);

    std::transform(s1, s1+l1, s2, output, std::bit_xor());

    luaL_pushresultsize(&B, l1);
    return 1;
}

int l_isalnum(lua_State* L)
{
    lua_Integer i = luaL_checkinteger(L, 1);
    lua_pushboolean(L, isalnum(i));
    return 1;
}


void push_configuration(lua_State* L, configuration const& cfg)
{
    char const* const configs[][2] = {
        {"lua_filename", cfg.lua_filename},
        {"irc_socat", cfg.irc_socat},
        {"irc_nick", cfg.irc_nick},
        {"irc_pass", cfg.irc_pass},
        {"irc_user", cfg.irc_user},
        {"irc_gecos", cfg.irc_gecos},
        {"irc_challenge_key", cfg.irc_challenge_key},
        {"irc_challenge_password", cfg.irc_challenge_password},
        {"irc_oper_username", cfg.irc_oper_username},
        {"irc_oper_password", cfg.irc_oper_password},
        {"irc_sasl_mechanism", cfg.irc_sasl_mechanism},
        {"irc_sasl_username", cfg.irc_sasl_username},
        {"irc_sasl_password", cfg.irc_sasl_password},
        {"irc_capabilities", cfg.irc_capabilities},
        {"network_filename", cfg.network_filename},
        {"irc_sasl_key", cfg.irc_sasl_key},
        {"irc_sasl_authzid", cfg.irc_sasl_authzid},
    };

    lua_createtable(L, 0, std::size(configs));
    for (auto && x : configs) {
        lua_pushstring(L, x[1]);
        lua_setfield(L, -2, x[0]);
    }
}

int l_reset_delay(lua_State* L) {
    app::from_lua(L)->reset_delay();
    return 0;
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
    char const* str = luaL_checklstring(L, 1, &n);

    luaL_Buffer B;
    luaL_buffinitsize(L, &B, n);
    std::transform(str, str+n, B.b, [charmap](char c) {
        return charmap[uint8_t(c)];
    });
    luaL_pushresultsize(&B, n);
    return 1;
}

luaL_Reg const applib_module[] = {
    { "to_base64", l_to_base64 },
    { "from_base64", l_from_base64 },
    { "send_irc", l_send_irc },
    { "dnslookup", l_dnslookup },
    { "pton", l_pton },
    { "shutdown", l_shutdown },
    { "newtimer", l_newtimer },
    { "newwatcher", l_newwatcher },
    { "setmodule", l_setmodule },
    { "raise", l_raise },
    { "xor_strings", l_xor_strings },
    { "isalnum", l_isalnum },
    { "reset_delay", l_reset_delay },
    { "irccase", l_irccase },
    {}
};

int l_print(lua_State* L)
{
    auto const a = app::from_lua(L);

    int n = lua_gettop(L);  /* number of arguments */

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


void load_logic(lua_State* const L, char const* const filename)
{
    int r = luaL_loadfile(L, filename);
    if (LUA_OK == r) {
        safecall(L, "load_logic:call", 0);
    } else {
        auto const a = app::from_lua(L);
        size_t len;
        char const* err = lua_tolstring(L, -1, &len);
        endwin();
        std::cerr << "error in load_logic:load: " << err << std::endl;
        lua_pop(L, 1);
    }
}

void lua_callback(lua_State* L, char const* key)
{
    /* args */
    lua_pushcfunction(L, lua_callback_worker); /* args f */
    lua_insert(L, 1); /* f args */
    lua_pushstring(L, key); /* f args key */
    safecall(L, key, lua_gettop(L) - 1);
}

void pushircmsg(lua_State* L, ircmsg const& msg)
{
    lua_createtable(L, msg.args.size(), 3);

    lua_createtable(L, 0, msg.tags.size());
    for (auto && tag : msg.tags) {
        push_stringview(L, tag.key);
        if (tag.hasval()) {
            push_stringview(L, tag.val);
        } else {
            lua_pushboolean(L, 1);
        }
        lua_settable(L, -3);
    }
    lua_setfield(L, -2, "tags");

    if (msg.hassource()) {
        push_stringview(L, msg.source);
        lua_setfield(L, -2, "source");
    }

    int code;
    auto res = std::from_chars(msg.command.begin(), msg.command.end(), code);
    if (*res.ptr == '\0') {
        lua_pushinteger(L, code);
    } else {
        push_stringview(L, msg.command);
    }
    lua_setfield(L, -2, "command");

    int argix = 1;
    for (auto arg : msg.args) {
        push_stringview(L, arg);
        lua_rawseti(L, -2, argix++);
    }
}

void prepare_globals(lua_State* L, configuration const& cfg)
{
    /* setup libraries */
    luaL_openlibs(L);
    luaL_requiref(L, "ncurses", luaopen_myncurses, 1);
    lua_pop(L, 1);

    #ifdef GEOIP_FOUND
    luaL_requiref(L, "mygeoip", luaopen_mygeoip, 1);
    lua_pop(L, 1);
    #endif

    luaL_newlib(L, applib_module);
    lua_setglobal(L, "snowcone");

    /* Overwrite the lualib print with the custom one */
    lua_pushcfunction(L, l_print);
    lua_setglobal(L, "print");

    /* install configuration */
    push_configuration(L, cfg);
    lua_setglobal(L, "configuration");

    /* populate arg */
    lua_createtable(L, 0, 1);
    lua_pushstring(L, cfg.lua_filename);
    lua_rawseti(L, -2, 0);
    lua_setglobal(L, "arg");

    l_ncurses_resize(L);
}
