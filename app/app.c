#include <assert.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <ncurses.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include <ircmsg.h>
#include <myncurses.h>
#include <mygeoip.h>

#include "app.h"
#include "write.h"
#include "base64.h"

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

static inline struct app **app_ref(lua_State *L)
{
    return lua_getextraspace(L);
}

static int error_handler(lua_State *L)
{
    const char* msg = luaL_tolstring(L, 1, NULL);
    luaL_traceback(L, L, msg, 1);
    return 1;
}

static int
safecall(lua_State *L, char const* location, int args, int results)
{
    lua_pushcfunction(L, error_handler);
    // f a1 a2.. eh
    lua_insert(L, -2-args);
    // eh f a1 a2..

    int r = lua_pcall(L, args, results, -2-args);
    if (LUA_OK == r) {
        lua_remove(L, -1-results);
    } else {
        struct app * const a = *app_ref(L);
        size_t len;
        char const* err = luaL_tolstring(L, -1, &len);
        if (a->console) {
            to_write(a->console, err, len);
            to_write(a->console, "\n", 1);
        } else {
            endwin();
            fprintf(stderr, "error in %s: %s\n", location, err);
        }
        lua_pop(L, 3); /* error, error string, handler */
    }

    return r;
}

static void
on_dnslookup(uv_getaddrinfo_t *req, int status, struct addrinfo *res)
{
    struct app * const a = req->loop->data;
    lua_State * const L = a->L;

    lua_pushcfunction(L, error_handler);

    lua_rawgetp(L, LUA_REGISTRYINDEX, req);
    lua_pushnil(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, req);

    if (0 == status) {
        do_dns(a, res); // pushes two arrays
        lua_pushnil(L);
        uv_freeaddrinfo(res);
    } else {
        lua_pushnil(L);
        lua_pushnil(L);
        lua_pushstring(L, uv_strerror(status));
    }
    free(req);

    safecall(L, "dnslookup callback", 3, 0);
}

static int
app_dnslookup(lua_State *L)
{
    struct app * const a = *app_ref(L);
    char const* hostname = luaL_checkstring(L, 1);
    luaL_checkany(L, 2);
    lua_settop(L, 2);

    uv_getaddrinfo_t *req = malloc(sizeof *req);
    assert(req);

    struct addrinfo const hints = { .ai_socktype = SOCK_STREAM };
    int r = uv_getaddrinfo(a->loop, req, on_dnslookup, hostname, NULL, &hints);
    if (0 != r)
    {
        free(req);
        return luaL_error(L, "dnslookup: %s", uv_strerror(r));
    }

    lua_rawsetp(L, LUA_REGISTRYINDEX, req);

    return 0;
}

static int app_print(lua_State *L)
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
    uv_stop(a->loop);
    return 0;
}

static void load_logic(lua_State *L, char const *filename)
{
    int res = luaL_loadfile(L, filename) || safecall(L, "load_logic", 0, 1);
    if (res == LUA_OK)
    {
        lua_rawsetp(L, LUA_REGISTRYINDEX, &logic_module);
    }
}

static void push_configuration(lua_State *L, struct configuration *cfg)
{
    lua_createtable(L, 0, 17);
    lua_pushstring(L, cfg->console_node);
    lua_setfield(L, -2, "console_node");
    lua_pushstring(L, cfg->console_service);
    lua_setfield(L, -2, "console_service");
    lua_pushstring(L, cfg->lua_filename);
    lua_setfield(L, -2, "lua_filename");
    lua_pushstring(L, cfg->irc_socat);
    lua_setfield(L, -2, "irc_socat");
    lua_pushstring(L, cfg->irc_nick);
    lua_setfield(L, -2, "irc_nick");
    lua_pushstring(L, cfg->irc_pass);
    lua_setfield(L, -2, "irc_pass");
    lua_pushstring(L, cfg->irc_user);
    lua_setfield(L, -2, "irc_user");
    lua_pushstring(L, cfg->irc_gecos);
    lua_setfield(L, -2, "irc_gecos");
    lua_pushstring(L, cfg->irc_challenge_key);
    lua_setfield(L, -2, "irc_challenge_key");
    lua_pushstring(L, cfg->irc_challenge_password);
    lua_setfield(L, -2, "irc_challenge_password");
    lua_pushstring(L, cfg->irc_oper_username);
    lua_setfield(L, -2, "irc_oper_username");
    lua_pushstring(L, cfg->irc_oper_password);
    lua_setfield(L, -2, "irc_oper_password");
    lua_pushstring(L, cfg->irc_sasl_mechanism);
    lua_setfield(L, -2, "irc_sasl_mechanism");
    lua_pushstring(L, cfg->irc_sasl_username);
    lua_setfield(L, -2, "irc_sasl_username");
    lua_pushstring(L, cfg->irc_sasl_password);
    lua_setfield(L, -2, "irc_sasl_password");
    lua_pushstring(L, cfg->irc_capabilities);
    lua_setfield(L, -2, "irc_capabilities");
    lua_pushstring(L, cfg->network_filename);
    lua_setfield(L, -2, "network_filename");
}

static void app_prepare_globals(struct app *a)
{
    lua_State * const L = a->L;

    luaL_openlibs(L);
    
    luaL_requiref(L, "ncurses", luaopen_myncurses, 1);
    lua_pop(L, 1);
    l_ncurses_resize(L);

    lua_pushcfunction(L, app_to_base64);
    lua_setglobal(L, "to_base64");
    lua_pushcfunction(L, app_print);
    lua_setglobal(L, "print");
    lua_pushcfunction(L, l_writeirc);
    lua_setglobal(L, "send_irc");
    lua_pushcfunction(L, app_dnslookup);
    lua_setglobal(L, "dnslookup");
    lua_pushcfunction(L, l_shutdown);
    lua_setglobal(L, "shutdown");
    luaopen_mygeoip(L);
    lua_setglobal(L, "mygeoip");

    push_configuration(L, a->cfg);
    lua_setglobal(L, "configuration");

    lua_createtable(L, 0, 1);
    lua_pushstring(L, a->cfg->lua_filename);
    lua_rawseti(L, -2, 0);
    lua_setglobal(L, "arg");
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

struct app *app_new(uv_loop_t *loop, struct configuration *cfg)
{
    struct app *a = malloc(sizeof *a);
    assert(a);

    *a = (struct app) {
        .loop = loop,
        .cfg = cfg,
    };

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
    lua_pushcfunction(L, error_handler); /* args eh */
    lua_pushcfunction(L, lua_callback_worker); /* args eh f */
    lua_pushstring(L, key); /* args eh f key */
    lua_rotate(L, -3-args, -args); /* eh f key args */

    safecall(L, key, 1+args, 0);
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

void do_timer(struct app *a)
{
    lua_callback(a->L, "on_timer", 0);
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
