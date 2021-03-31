#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <ncurses.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "app.h"
#include "ircmsg.h"
#include "lua-ncurses.h"
#include "mygeoip.h"

static char logic_module;

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

struct app
{
    lua_State *L;
    char const *logic_filename;
    void *write_data;
    void (*write_cb)(void *, char const* bytes, size_t n);
};

static int app_parseirc(lua_State *L) 
{
    char const* msg = luaL_checkstring(L, 1);
    char *dup = strdup(msg);
    struct ircmsg imsg;
    int err = parse_irc_message(&imsg, dup);
    if (err) {
        free(dup);
        luaL_error(L, "parse error %d", err);
    }
    pushircmsg(L, &imsg);
    free(dup);
    return 1;
}

static int error_handler(lua_State *L)
{
    const char* msg = luaL_tolstring(L, 1, NULL);
    luaL_traceback(L, L, msg, 1);
    return 1;
}

static int app_print(lua_State *L)
{
    struct app * const a = *app_ref(L);

    if (a->write_cb)
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
    
        a->write_cb(a->write_data, msg, msglen);
    }

    return 0;
}

static void load_logic(lua_State *L, char const *filename)
{
    lua_pushcfunction(L, error_handler);
    int res = luaL_loadfile(L, filename) || lua_pcall(L, 0, 1, -2);
    if (res == LUA_OK)
    {
        lua_rawsetp(L, LUA_REGISTRYINDEX, &logic_module);
    }
    else
    {
        char const *err = lua_tostring(L, -1);
        endwin();
        fprintf(stderr, "Failed to callback logic: %s\n%s\n", filename, err);
        lua_pop(L, 1); /* error message */
    }
    lua_pop(L, 1); /* error handler */
}

static void app_prepare_globals(lua_State *L, char const* script_name)
{
    luaL_openlibs(L);
    
    luaL_requiref(L, "ncurses", luaopen_ncurses, 1);
    lua_pop(L, 1);
    l_ncurses_resize(L);

    lua_pushcfunction(L, &app_print);
    lua_setglobal(L, "print");

    lua_pushcfunction(L, app_parseirc);
    lua_setglobal(L, "parseirc");

    luaopen_mygeoip(L);
    lua_setglobal(L, "mygeoip");

    lua_createtable(L, 0, 1);
    lua_pushstring(L, script_name);
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
    *app_ref(a->L) = a;

    app_prepare_globals(a->L, a->logic_filename);
    load_logic(a->L, a->logic_filename);
}

struct app *app_new(char const *logic)
{
    struct app *a = malloc(sizeof *a);
    *a = (struct app) {
        .logic_filename = logic,
    };

    start_lua(a);
    return a;
}

void app_reload(struct app *a)
{
    load_logic(a->L, a->logic_filename);
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

    if (lua_pcall(L, 1+args, 0, -3-args))
    {
        struct app * const a = *app_ref(L);
        size_t len;
        char const* err = lua_tolstring(L, -1, &len);
        if (a->write_cb) {
            a->write_cb(a->write_data, err, len);
            a->write_cb(a->write_data, "\n", 1);
        } else {
            endwin();
            fprintf(stderr, "%s\n", err);
        }
        lua_pop(L, 1); /* drop the error */
    }
    lua_pop(L, 1); /* drop error handler */
}

void do_command(
    struct app *a,
    char const* line,
    void *write_data,
    void (*write_cb)(void*, char const*, size_t))
{
    a->write_cb = write_cb;
    a->write_data = write_data;

    if (*line == '/')
    {
        line++;
        if (!strcmp(line, "reload"))
        {
            load_logic(a->L, a->logic_filename);
        }
        else if (!strcmp(line, "restart"))
        {
            start_lua(a);
        }
        else
        {
            char const* msg = "Unknown command\n";
            write_cb(write_data, msg, strlen(msg));
        }
    }
    else
    {
        lua_pushstring(a->L, line);
        lua_callback(a->L, "on_input", 1);
    }
    
    a->write_cb = NULL;
    a->write_data = NULL;
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

static int l_writeirc(lua_State *L)
{
    void *data = lua_touserdata(L, lua_upvalueindex(1));
    void (*cb)(void*, char const*, size_t) = lua_touserdata(L, lua_upvalueindex(2));
    size_t len;
    char const* cmd = luaL_checklstring(L, 1, &len);
    cb(data, cmd, len);
    return 0;
}

void app_set_irc(struct app *a, void *data, void (*cb)(void*, char const*, size_t))
{
    lua_pushlightuserdata(a->L, data);
    lua_pushlightuserdata(a->L, cb);
    lua_pushcclosure(a->L, l_writeirc, 2);
    lua_setglobal(a->L, "send_irc");
}

void app_set_window_size(struct app *a)
{
    l_ncurses_resize(a->L);
}

void do_mrs(struct app *a, char const* name, struct addrinfo const* ai)
{
    char buffer[INET6_ADDRSTRLEN];
    lua_State * const L = a->L;
    lua_newtable(L);
    lua_Integer i = 0;
    while (ai) {
        i++;
        struct sockaddr_in a;
        getnameinfo(ai->ai_addr, ai->ai_addrlen, buffer, sizeof buffer, NULL, 0, NI_NUMERICHOST);
        lua_pushstring(L, buffer);
        lua_rawseti(L, -2, i);
        ai = ai->ai_next;
    }
    lua_pushstring(L, name);
    lua_setfield(L, -2, "name");
    lua_callback(L, "on_mrs", 1);
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