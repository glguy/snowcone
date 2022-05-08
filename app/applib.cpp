#include "applib.hpp"

#include "app.hpp"
#include "lua_uv_dnslookup.hpp"
#include "lua_uv_filewatcher.hpp"
#include "lua_uv_timer.hpp"
#include "safecall.hpp"
#include "uv.hpp"
#include "uvaddrinfo.hpp"
#include "write.hpp"

extern "C" {
#include <myncurses.h>
#if HAS_GEOIP
#include <mygeoip.h>
#endif
#include <mybase64.h>

#include "lauxlib.h"
}

#include <ncurses.h>

#include <cstdio>
#include <cstring>
#include <iostream>
#include <locale>

namespace { // lua support for app

char logic_module;

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

    union {
        struct in_addr a4;
        struct in6_addr a6;
    } dst;

    int res = inet_pton(ipv6 ? AF_INET6 : AF_INET, p, &dst);

    if (res == 1)
    {
        lua_pushlstring(L, (char*)&dst, ipv6 ? sizeof (struct in6_addr) : sizeof (struct in_addr));
        return 1;
    }
    else if (res < 0)
    {
        lua_pushnil(L);
        lua_pushfstring(L, "pton: %s", strerror(errno));
        return 2;
    }
    else
    {
        lua_pushnil(L);
        lua_pushstring(L, "pton: bad address");
        return 2;
    }
}

void push_addrinfos(lua_State* L, uv_loop_t* loop, addrinfo* ai)
{
    AddrInfo addrinfos {ai};
    size_t n = std::distance(addrinfos.begin(), addrinfos.end());

    lua_createtable(L, n, 0); // printable addresses
    lua_Integer i = 1;

    for (auto const& a : addrinfos) {
        uv_getnameinfo_t req;
        uvok(uv_getnameinfo(loop, &req, nullptr, a.ai_addr, NI_NUMERICHOST));
        lua_pushstring(L, req.host);
        lua_rawseti(L, -2, i++);
    }
}

void on_dnslookup(uv_getaddrinfo_t* req, int status, addrinfo* res)
{
    auto const a = static_cast<app*>(req->loop->data);
    auto const L = a->L;

    lua_rawgetp(L, LUA_REGISTRYINDEX, req);
    lua_pushnil(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, req);
    delete req;

    if (0 == status) {
        push_addrinfos(L, &a->loop, res);
        lua_pushnil(L);
    } else {
        lua_pushnil(L);
        lua_pushstring(L, uv_strerror(status));
    }

    safecall(L, "dnslookup callback", 2);
}

int l_dnslookup(lua_State* L)
{
    auto const a = app_ref(L);
    char const* hostname = luaL_checkstring(L, 1);
    luaL_checkany(L, 2);
    lua_settop(L, 2);


    addrinfo hints {};
    hints.ai_socktype = SOCK_STREAM;

    auto req = new uv_getaddrinfo_t;
    int r = uv_getaddrinfo(&a->loop, req, on_dnslookup, hostname, nullptr, &hints);
    if (0 != r) {
        delete req;
        return luaL_error(L, "dnslookup: %s", uv_strerror(r));
    }

    lua_rawsetp(L, LUA_REGISTRYINDEX, req);

    return 0;
}

int l_raise(lua_State* L)
{
    lua_Integer s = luaL_checkinteger(L, 1);
    int r = raise(s);
    if (r != 0)
    {
        return luaL_error(L, "raise: %s", strerror(errno));
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
    mybase64_encode(input, input_len, output);
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
    ssize_t len = mybase64_decode(input, input_len, output);
    if (0 <= len)
    {
        luaL_pushresultsize(&B, len);
        return 1;
    }
    else
    {
        lua_pushnil(L);
        lua_pushstring(L, "base64 decoding error");
        return 2;
    }
}

int l_send_irc(lua_State* L)
{
    auto const a = app_ref(L);

    size_t len;
    char const* cmd = luaL_optlstring(L, 1, nullptr, &len);

    if (nullptr == a->irc)
    {
        return luaL_error(L, "IRC not connected");
    }

    if (nullptr == cmd)
    {
        auto shutdown = new uv_shutdown_t;
        uvok(uv_shutdown(shutdown, a->irc, [](uv_shutdown_t* req, auto stat) {
            delete req;
        }));
        a->irc = nullptr;
    }
    else
    {
        to_write(a->irc, cmd, len);
    }

    return 0;
}

int l_shutdown(lua_State* L)
{
    auto const a = app_ref(L);
    a->closing = true;
    
    uv_close_xx(&a->winch);
    uv_close_xx(&a->input);
    uv_close_xx(&a->reconnect);

    return 0;
}

int l_setmodule(lua_State* L)
{
    lua_rawsetp(L, LUA_REGISTRYINDEX, &logic_module);
    return 0;
}

int l_newtimer(lua_State* L)
{
    auto const a = app_ref(L);
    push_new_uv_timer(L, &a->loop);
    return 1;
}

int l_newwatcher(lua_State* L)
{
    auto const a = app_ref(L);
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

    for (size_t i = 0; i < l1; i++)
    {
        output[i] = s1[i] ^ s2[i];
    }

    luaL_pushresultsize(&B, l1);
    return 1;
}

int l_isalnum(lua_State* L)
{
    lua_Integer i = luaL_checkinteger(L, 1);
    lua_pushboolean(L, isalnum(i));
    return 1;
}


void push_configuration(lua_State* L, configuration* cfg)
{
    char const* const configs[][2] = {
        {"lua_filename", cfg->lua_filename},
        {"irc_socat", cfg->irc_socat},
        {"irc_nick", cfg->irc_nick},
        {"irc_pass", cfg->irc_pass},
        {"irc_user", cfg->irc_user},
        {"irc_gecos", cfg->irc_gecos},
        {"irc_challenge_key", cfg->irc_challenge_key},
        {"irc_challenge_password", cfg->irc_challenge_password},
        {"irc_oper_username", cfg->irc_oper_username},
        {"irc_oper_password", cfg->irc_oper_password},
        {"irc_sasl_mechanism", cfg->irc_sasl_mechanism},
        {"irc_sasl_username", cfg->irc_sasl_username},
        {"irc_sasl_password", cfg->irc_sasl_password},
        {"irc_capabilities", cfg->irc_capabilities},
        {"network_filename", cfg->network_filename},
        {"irc_sasl_key", cfg->irc_sasl_key},
        {"irc_sasl_authzid", cfg->irc_sasl_authzid},
    };

    lua_createtable(L, 0, std::size(configs));
    for (auto && x : configs) {
        lua_pushstring(L, x[1]);
        lua_setfield(L, -2, x[0]);
    }
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
    {}
};

int l_print(lua_State* L)
{
    auto const a = app_ref(L);

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


void load_logic(lua_State* L, char const* filename)
{
    int r = luaL_loadfile(L, filename);
    if (LUA_OK == r) {
        safecall(L, "load_logic:call", 0);
    } else {
        auto const a = app_ref(L);
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
        if (tag.val) {
            lua_pushstring(L, tag.val);
        } else {
            lua_pushboolean(L, 1);
        }
        lua_setfield(L, -2, tag.key);
    }
    lua_setfield(L, -2, "tags");

    lua_pushstring(L, msg.source);
    lua_setfield(L, -2, "source");

    char *end;
    long code = strtol(msg.command, &end, 10);
    if (*end == '\0') {
        lua_pushinteger(L, code);
    } else {
        lua_pushstring(L, msg.command);
    }
    lua_setfield(L, -2, "command");

    int argix = 1;
    for (auto arg : msg.args) {
        lua_pushstring(L, arg);
        lua_rawseti(L, -2, argix++);
    }
}

void prepare_globals(lua_State* L, configuration* cfg)
{
    /* setup libraries */
    luaL_openlibs(L);
    luaL_requiref(L, "ncurses", luaopen_myncurses, 1);
    lua_pop(L, 1);

    #if HAS_GEOIP
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
    lua_pushstring(L, cfg->lua_filename);
    lua_rawseti(L, -2, 0);
    lua_setglobal(L, "arg");

    l_ncurses_resize(L);
}