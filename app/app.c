#include <assert.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>

#include <ncurses.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include <ircmsg.h>
#include <myncurses.h>

#if HAS_GEOIP
#include <mygeoip.h>
#endif

#include "app.h"
#include "base64.h"
#include "lua_uv_timer.h"
#include "lua_uv_filewatcher.h"
#include "safecall.h"
#include "write.h"

static char logic_module;

static void lua_callback(lua_State *L, char const *key, int args);
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

    lua_pushstring(L, msg->command);
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
    struct app * const a = req->loop->data;
    lua_State * const L = a->L;

    lua_rawgetp(L, LUA_REGISTRYINDEX, req);
    lua_pushnil(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, req);
    free(req);

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

    uv_getaddrinfo_t *req = malloc(sizeof *req);
    assert(req);

    struct addrinfo const hints = { .ai_socktype = SOCK_STREAM };
    int r = uv_getaddrinfo(&a->loop, req, on_dnslookup, hostname, NULL, &hints);
    if (0 != r)
    {
        free(req);
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
                (void)luaL_tolstring(L, i, NULL); // leaves string on stack
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

static int app_to_base64(lua_State *L)
{
    size_t input_len;
    char const* input = luaL_checklstring(L, 1, &input_len);
    size_t outlen = (input_len + 2) / 3 * 4 + 1;
    char *output = malloc(outlen);
    assert(output);

    snowcone_base64(input, input_len, output);
    lua_pushstring(L, output);
    free(output);
    return 1;
}

static int l_writeirc(lua_State *L)
{
    struct app * const a = *app_ref(L);

    size_t len;
    char const* cmd = luaL_checklstring(L, 1, &len);

    if (NULL == a->irc)
    {
        return luaL_error(L, "IRC not connected");
    }

    to_write(a->irc, cmd, len);
    return 0;
}

static int l_shutdown(lua_State *L)
{
    struct app * const a = *app_ref(L);
    a->closing = true;

    for (size_t i = 0; i < a->listeners_len; i++)
    {
        uv_close((uv_handle_t*)&a->listeners[i], NULL);
    }

    uv_close((uv_handle_t*)&a->input, NULL);
    uv_close((uv_handle_t*)&a->winch, NULL);
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

static luaL_Reg M[] = {
    { "to_base64", app_to_base64 },
    { "send_irc", l_writeirc },
    { "dnslookup", l_dnslookup },
    { "pton", l_pton },
    { "shutdown", l_shutdown },
    { "newtimer", l_newtimer },
    { "newwatcher", l_newwatcher },
    { "setmodule", l_setmodule },
    { "raise", l_raise },
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
    struct app *a = malloc(sizeof *a);
    assert(a);

    *a = (struct app) {
        .cfg = cfg,
        .loop.data = a,
    };

    int r = uv_loop_init(&a->loop);
    assert(0 == r);

    r = uv_poll_init(&a->loop, &a->input, STDIN_FILENO);
    assert(0 == r);

    r = uv_signal_init(&a->loop, &a->winch);
    assert(0 == r);

    start_lua(a);
    return a;
}

void app_reload(struct app *a)
{
    load_logic(a->L, a->cfg->lua_filename);
}

void app_free(struct app *a)
{
    if (a)
    {
        uv_loop_close(&a->loop);
        free(a->listeners);
        lua_close(a->L);
        free(a);
    }
}

static int lua_callback_worker(lua_State *L)
{
    int module_ty = lua_rawgetp(L, LUA_REGISTRYINDEX, &logic_module);
    if (module_ty != LUA_TNIL)
    {
        lua_rotate(L, 1, -1);
        lua_gettable(L, -2);
        lua_rotate(L, 1, 1);
        lua_pop(L, 1);
        int args = lua_gettop(L) - 1;
        lua_call(L, args, 0);
    }
    return 0;
}

static void lua_callback(lua_State *L, char const *key, int args)
{
    /* args */
    lua_pushcfunction(L, lua_callback_worker); /* args f */
    lua_pushstring(L, key); /* args f key */
    lua_rotate(L, -2-args, -args); /* eh f key args */

    safecall(L, key, 1+args);
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
        lua_callback(a->L, "on_input", 1);
    }
    
    a->console = NULL;
}

void do_keyboard(struct app *a, long key)
{
    lua_pushinteger(a->L, key);
    lua_callback(a->L, "on_keyboard", 1);
}

void app_set_irc(struct app *a, uv_stream_t *irc)
{
    a->irc = irc;
    lua_callback(a->L, "on_connect", 0);
}

void app_clear_irc(struct app *a)
{
    a->irc = NULL;
    lua_callback(a->L, "on_disconnect", 0);
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
        int r = getnameinfo(ai->ai_addr, ai->ai_addrlen, buffer, sizeof buffer, NULL, 0, NI_NUMERICHOST);
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
    lua_callback(a->L, "on_irc", 1);
}

void do_mouse(struct app *a, int y, int x)
{
    lua_pushinteger(a->L, y);
    lua_pushinteger(a->L, x);
    lua_callback(a->L, "on_mouse", 2);
}
