#include <assert.h>
#include <ctype.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>

#include <vector>
#include <iostream>

#include <ncurses.h>

extern "C" {
#include "lauxlib.h"
#include "lualib.h"

#include <ircmsg.h>
#include <myncurses.h>
#if HAS_GEOIP
#include <mygeoip.h>
#endif
#include "mybase64.h"
}

#include "app.hpp"
#include "uv.hpp"
#include "lua_uv_filewatcher.hpp"
#include "lua_uv_timer.hpp"
#include "safecall.hpp"
#include "write.hpp"

static char logic_module;

static void lua_callback(lua_State *L, char const *key);
static void do_dns(struct app *a, struct addrinfo const* ai);

static void pushircmsg(lua_State *L, struct ircmsg const* msg)
{
    lua_createtable(L, msg->args_n, 3);

    lua_createtable(L, 0, msg->tags_n);
    for (int i = 0; i < msg->tags_n; i++) {
        if (msg->tags[i].val)
        {
            lua_pushstring(L, msg->tags[i].val);
        }
        else
        {
            lua_pushboolean(L, 1);
        }
        lua_setfield(L, -2, msg->tags[i].key);
    }
    lua_setfield(L, -2, "tags");

    lua_pushstring(L, msg->source);
    lua_setfield(L, -2, "source");

    char *end;
    long code = strtol(msg->command, &end, 10);
    if (*end == '\0') {
        lua_pushinteger(L, code);
    } else {
        lua_pushstring(L, msg->command);
    }
    lua_setfield(L, -2, "command");

    for (int i = 0; i < msg->args_n; i++)
    {
        lua_pushstring(L, msg->args[i]);
        lua_rawseti(L, -2, i+1);
    }
}

static int l_pton(lua_State *L)
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

static void
on_dnslookup(uv_getaddrinfo_t *req, int status, struct addrinfo *res)
{
    auto const a = static_cast<app*>(req->loop->data);
    lua_State * const L = a->L;

    lua_rawgetp(L, LUA_REGISTRYINDEX, req);
    lua_pushnil(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, req);
    delete req;

    if (0 == status) {
        do_dns(a, res); // pushes two arrays
        lua_pushnil(L);
        uv_freeaddrinfo(res);
    } else {
        lua_pushnil(L);
        lua_pushnil(L);
        lua_pushstring(L, uv_strerror(status));
    }

    safecall(L, "dnslookup callback", 3);
}

static int
l_dnslookup(lua_State *L)
{
    struct app * const a = *app_ref(L);
    char const* hostname = luaL_checkstring(L, 1);
    luaL_checkany(L, 2);
    lua_settop(L, 2);

    auto req = new uv_getaddrinfo_t;

    struct addrinfo const hints = { .ai_socktype = SOCK_STREAM };
    int r = uv_getaddrinfo(&a->loop, req, on_dnslookup, hostname, nullptr, &hints);
    if (0 != r)
    {
        delete req;
        return luaL_error(L, "dnslookup: %s", uv_strerror(r));
    }

    lua_rawsetp(L, LUA_REGISTRYINDEX, req);

    return 0;
}

static int l_print(lua_State *L)
{
    struct app * const a = *app_ref(L);

    if (a->console)
    {
        int n = lua_gettop(L);  /* number of arguments */

        luaL_Buffer b;
        luaL_buffinit(L, &b);

        for (int i = 1; i <= n; i++) {
                (void)luaL_tolstring(L, i, nullptr); // leaves string on stack
                luaL_addvalue(&b); // consumes string
                if (i<n) luaL_addchar(&b, '\t');
        }
        luaL_addchar(&b, '\n');
        luaL_pushresult(&b);
        size_t msglen;
        char const* msg = lua_tolstring(L, -1, &msglen);
    
        to_write(a->console, msg, msglen);
    }

    return 0;
}

static int l_raise(lua_State *L)
{
    lua_Integer s = luaL_checkinteger(L, 1);
    int r = raise(s);
    if (r != 0)
    {
        return luaL_error(L, "raise: %s", strerror(errno));
    }
    return 0;
}

static int l_to_base64(lua_State *L)
{
    size_t input_len;
    char const* input = luaL_checklstring(L, 1, &input_len);
    size_t outlen = (input_len + 2) / 3 * 4 + 1;
    char *output = new char[outlen];
    assert(output);

    mybase64_encode(input, input_len, output);
    lua_pushstring(L, output);
    delete [] output;
    return 1;
}

static int l_from_base64(lua_State *L)
{
    size_t input_len;
    char const* input = luaL_checklstring(L, 1, &input_len);
    size_t outlen = (input_len + 3) / 4 * 3;
    
    std::vector<char> output(outlen);

    ssize_t len = mybase64_decode(input, input_len, output.data());
    if (0 <= len)
    {
        lua_pushlstring(L, output.data(), len);
        return 1;
    }
    else
    {
        lua_pushnil(L);
        lua_pushstring(L, "base64 decoding error");
        return 2;
    }
}

static int l_send_irc(lua_State *L)
{
    struct app * const a = *app_ref(L);

    size_t len;
    char const* cmd = luaL_optlstring(L, 1, nullptr, &len);

    if (nullptr == a->irc)
    {
        return luaL_error(L, "IRC not connected");
    }

    if (nullptr == cmd)
    {
        auto shutdown = new uv_shutdown_t;
        uvok(uv_shutdown(shutdown, a->irc, [](auto req, auto stat) {
            delete reinterpret_cast<uv_shutdown_t*>(req);
        }));
        a->irc = nullptr;
    }
    else
    {
        to_write(a->irc, cmd, len);
    }

    return 0;
}

static int l_shutdown(lua_State *L)
{
    auto const a = *app_ref(L);
    a->closing = true;

    for (auto &&l : a->listeners) {
        uv_close_xx(&l);
    }
    
    uv_poll_stop(&a->input);
    uv_signal_stop(&a->winch);
    
    auto t = new uv_timer_t;
    uv_timer_init(&a->loop, t);
    uv_timer_start(t, [](auto t) {
        auto const a = static_cast<app*>(t->loop->data);
        uv_close_xx(&a->winch);
        uv_close_xx(&a->input);
        uv_close_xx(t, [](auto t){
            delete reinterpret_cast<uv_timer_t*>(t);
        });

    }, 0, 0);

    return 0;
}

static int l_setmodule(lua_State *L)
{
    lua_rawsetp(L, LUA_REGISTRYINDEX, &logic_module);
    return 0;
}

static void load_logic(lua_State *L, char const *filename)
{
    int r = luaL_loadfile(L, filename);
    if (LUA_OK == r) {
        safecall(L, "load_logic:call", 0);
    } else {
        struct app * const a = *app_ref(L);
        size_t len;
        char const* err = lua_tolstring(L, -1, &len);
        if (a->console) {
            to_write(a->console, err, len);
            to_write(a->console, "\n", 1);
        } else {
            endwin();
            fprintf(stderr, "error in %s: %s\n", "load_logic:load", err);
        }
        lua_pop(L, 1);
    }
}

static void push_configuration(lua_State *L, struct configuration *cfg)
{
    char const* const configs[][2] = {
        {"console_node", cfg->console_node},
        {"console_service", cfg->console_service},
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

    size_t const n = sizeof configs / sizeof *configs;
    lua_createtable(L, 0, n);
    for (size_t i = 0; i < n; i++)
    {
        lua_pushstring(L, configs[i][1]);
        lua_setfield(L, -2, configs[i][0]);
    }
}

static int l_newtimer(lua_State *L)
{
    struct app * const a = *app_ref(L);
    push_new_uv_timer(L, &a->loop);
    return 1;
}

static int l_newwatcher(lua_State *L)
{
    struct app * const a = *app_ref(L);
    push_new_fs_event(L, &a->loop);
    return 1;
}

static int l_xor_strings(lua_State *L)
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

static int l_isalnum(lua_State *L)
{
    lua_Integer i = luaL_checkinteger(L, 1);
    lua_pushboolean(L, isalnum(i));
    return 1;
}

static luaL_Reg M[] = {
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

static void app_prepare_globals(struct app *a)
{
    lua_State * const L = a->L;

    /* setup libraries */
    luaL_openlibs(L);
    luaL_requiref(L, "ncurses", luaopen_myncurses, 1);
    lua_pop(L, 1);

    #if HAS_GEOIP
    luaL_requiref(L, "mygeoip", luaopen_mygeoip, 1);
    lua_pop(L, 1);
    #endif

    luaL_newlib(L, M);
    lua_setglobal(L, "snowcone");

    /* Overwrite the lualib print with the custom one */
    lua_pushcfunction(L, l_print);
    lua_setglobal(L, "print");

    /* install configuration */
    push_configuration(L, a->cfg);
    lua_setglobal(L, "configuration");

    /* populate arg */
    lua_createtable(L, 0, 1);
    lua_pushstring(L, a->cfg->lua_filename);
    lua_rawseti(L, -2, 0);
    lua_setglobal(L, "arg");

    l_ncurses_resize(L);
}

static void start_lua(struct app *a)
{
    if (a->L)
    {
        lua_close(a->L);
    }

    a->L = luaL_newstate();
    assert(a->L);

    struct app **aptr = app_ref(a->L);
    *aptr = a;

    app_prepare_globals(a);
    load_logic(a->L, a->cfg->lua_filename);
}

struct app *app_new(struct configuration *cfg)
{
    auto a = new app(cfg);
    uvok(uv_loop_init(&a->loop));
    uvok(uv_poll_init(&a->loop, &a->input, STDIN_FILENO));
    uvok(uv_signal_init(&a->loop, &a->winch));
    start_lua(a);
    return a;
}

void app_free(struct app *a)
{
    if (a)
    {
        lua_close(a->L);
        uvok(uv_loop_close(&a->loop));
        delete a;
    }
}

static int lua_callback_worker(lua_State *L)
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

static void lua_callback(lua_State *L, char const *key)
{
    /* args */
    lua_pushcfunction(L, lua_callback_worker); /* args f */
    lua_insert(L, 1); /* f args */
    lua_pushstring(L, key); /* f args key */
    safecall(L, key, lua_gettop(L) - 1);
}

void do_command(
    struct app *a,
    char const* line,
    uv_stream_t *console)
{
    a->console = console;

    if (*line == '/')
    {
        line++;
        if (!strcmp(line, "reload"))
        {
            load_logic(a->L, a->cfg->lua_filename);
        }
        else if (!strcmp(line, "restart"))
        {
            start_lua(a);
        }
        else
        {
            char const* msg = "Unknown command\n";
            to_write(console, msg, strlen(msg));
        }
    }
    else
    {
        lua_pushstring(a->L, line);
        lua_callback(a->L, "on_input");
    }
    
    a->console = nullptr;
}

void do_keyboard(struct app *a, long key)
{
    lua_pushinteger(a->L, key);
    lua_callback(a->L, "on_keyboard");
}

void app_set_irc(struct app *a, uv_stream_t *irc)
{
    a->irc = irc;
    lua_callback(a->L, "on_connect");
}

void app_clear_irc(struct app *a)
{
    a->irc = nullptr;
    lua_callback(a->L, "on_disconnect");
}

void app_set_window_size(struct app *a)
{
    l_ncurses_resize(a->L);
}

static void do_dns(struct app *a, struct addrinfo const* ai)
{
    char buffer[INET6_ADDRSTRLEN];
    lua_State * const L = a->L;
    lua_newtable(L);
    lua_newtable(L);
    lua_Integer i = 0;
    while (ai) {
        int r = getnameinfo(ai->ai_addr, ai->ai_addrlen, buffer, sizeof buffer, nullptr, 0, NI_NUMERICHOST);
        if (0 == r){
            i++;
            lua_pushstring(L, buffer);
            lua_rawseti(L, -3, i);

            switch (ai->ai_family) {
                default: lua_pushstring(L, ""); break;
                case PF_INET: {
                    struct sockaddr_in *sin = (struct sockaddr_in *)ai->ai_addr;
                    lua_pushlstring(L, (char*)&sin->sin_addr, sizeof sin->sin_addr);
                    break;
                }
                case PF_INET6: {
                    struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)ai->ai_addr;
                    lua_pushlstring(L, (char*)&sin6->sin6_addr, sizeof sin6->sin6_addr);
                    break;
                }
            }
            lua_rawseti(L, -2, i);
        } else {
            // I don't know when this could actually fail
            fprintf(stderr, "getnameinfo: %s\n", gai_strerror(r));
        }
        ai = ai->ai_next;
    }
}

void do_irc(struct app *a, struct ircmsg const* msg)
{
    pushircmsg(a->L, msg);
    lua_callback(a->L, "on_irc");
}

void do_irc_err(struct app *a, char const* msg)
{
    lua_pushstring(a->L, msg);
    lua_callback(a->L, "on_irc_err");
}

void do_mouse(struct app *a, int y, int x)
{
    lua_pushinteger(a->L, y);
    lua_pushinteger(a->L, x);
    lua_callback(a->L, "on_mouse");
}
