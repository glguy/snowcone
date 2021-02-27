#include <lua5.3/lua.h>
#include <lua5.3/lauxlib.h>
#include <lua5.3/lualib.h>

#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>

#include "app.h"

static char logic_module;

static inline struct app *get_app(lua_State *L)
{
    return *(struct app **)lua_getextraspace(L);
}

static inline void set_app(lua_State *L, struct app *a)
{
    *(struct app **)lua_getextraspace(L) = a;
}

struct app
{
    lua_State *L;
    char const *logic_filename;
    void *write_data;
    void (*write_cb)(void *, char const* bytes, size_t n);
};

static int error_handler(lua_State *L)
{
    const char* msg = luaL_tolstring(L, 1, NULL);
    luaL_traceback(L, L, msg, 1);
    return 1;
}

static int app_print(lua_State *L)
{
    struct app *a = get_app(L);

    if (a->write_cb)
    {
        int n = lua_gettop(L);  /* number of arguments */

        luaL_Buffer b;
        luaL_buffinit(L, &b);

        for (int i = 1; i <= n; i++) {
                (void)luaL_tolstring(L, i, NULL); // leaves string on stack
                luaL_addvalue(&b); // consumes string
                luaL_addchar(&b, i==n ? '\n' : '\t');
        }

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
    int res = luaL_loadfile(L, filename) || lua_pcall(L, 0, 1, 1);
    if (res == LUA_OK)
    {
        lua_rawsetp(L, LUA_REGISTRYINDEX, &logic_module);
    }
    else
    {
        char const *err = lua_tostring(L, -1);
        fprintf(stderr, "Failed to callback logic: %s\n%s\n", filename, err);
        lua_pop(L, 1); /* error message */
    }
    lua_pop(L, 1); /* error handler */
}

static void start_lua(struct app *a)
{
    if (a->L)
    {
        lua_close(a->L);
    }
    a->L = luaL_newstate();
    set_app(a->L, a);

    luaL_openlibs(a->L);

    lua_pushcfunction(a->L, &app_print);
    lua_setglobal(a->L, "print");

    load_logic(a->L, a->logic_filename);
}

struct app *app_new(char const *logic)
{
    struct app *a = malloc(sizeof *a);
    *a = (struct app) {
        .logic_filename = logic,
        .L = NULL,
        .write_cb = NULL,
        .write_data = NULL,
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
        lua_pushvalue(L, 1);
        lua_gettable(L, -2);
        lua_pushvalue(L, 2);
        lua_call(L, 1, 0);
    }
    return 0;
}

static void lua_callback(lua_State *L, char const *key, char const *arg)
{
    lua_pushcfunction(L, error_handler);
    lua_pushcfunction(L, lua_callback_worker);
    lua_pushstring(L, key);
    lua_pushstring(L, arg);

    if (lua_pcall(L, 2, 0, -4))
    {
        struct app *a = get_app(L);
        size_t len;
        char const* err = lua_tolstring(L, -1, &len);
        a->write_cb(a->write_data, err, len);
        a->write_cb(a->write_data, "\n", 1);
        lua_pop(L, 1); /* drop the error */
    }
    lua_pop(L, 1); /* drop error handler */
}

void do_command(struct app *a, char *line)
{
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
    }
    else
    {
        lua_callback(a->L, "on_input", line);
    }
}

void do_snote(struct app *a, char *line)
{
    lua_callback(a->L, "on_snote", line);
}

void do_timer(struct app *a)
{
    lua_callback(a->L, "on_timer", NULL);
}

void app_set_writer(struct app *a, void *data, void (*cb)(void*, char const*, size_t))
{
    a->write_data = data;
    a->write_cb = cb;
}

void app_set_window_size(struct app *a, int width, int height)
{
    lua_pushinteger(a->L, width);
    lua_setglobal(a->L, "tty_width");
    lua_pushinteger(a->L, height);
    lua_setglobal(a->L, "tty_height");
}
