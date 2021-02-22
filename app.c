#include <lua5.3/lua.h>
#include <lua5.3/lauxlib.h>
#include <lua5.3/lualib.h>

#include <string.h>
#include <stdlib.h>

#include "app.h"

static char logic_module;

struct app
{
    lua_State *L;
    char const *logic_filename;
};

static void load_logic(lua_State *L, char const *filename)
{
    int res = luaL_loadfile(L, filename) || lua_pcall(L, 0, 1, 0);
    if (res == LUA_OK)
    {
        lua_rawsetp(L, LUA_REGISTRYINDEX, &logic_module);
    }
    else
    {
        size_t len;
        char const *err = luaL_tolstring(L, -1, &len);
        printf("Failed to load logic: %s\n", err);
        lua_pop(L, 1);
    }
}

struct app *app_new(char const *logic)
{
    struct app *a = malloc(sizeof *a);

    a->L = luaL_newstate();
    a->logic_filename = logic;

    luaL_openlibs(a->L);
    load_logic(a->L, logic);

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
    char const *key = luaL_checkstring(L, 1);
    char const *arg = luaL_checkstring(L, 2);

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
    lua_pushcfunction(L, lua_callback_worker);
    lua_pushstring(L, key);
    lua_pushstring(L, arg);

    if (lua_pcall(L, 2, 0, 0))
    {
        char const *err = lua_tostring(L, -1);
        printf("Failed to load logic: %s\n", err);
        lua_pop(L, 1);
    }
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
