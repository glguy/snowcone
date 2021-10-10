#include <assert.h>

#include "lua_uv_timer.h"
#include "lauxlib.h"
#include "safecall.h"

static void on_close(uv_handle_t *handle)
{
    lua_State * const L = handle->data;
    lua_pushnil(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, handle);
}

static int l_close(lua_State *L)
{
    uv_timer_t *timer = luaL_checkudata(L, 1, "uv_timer");
    uv_close((uv_handle_t*)timer, on_close);
    return 0;
}

static void on_timer(uv_timer_t *timer)
{
    lua_State * const L = timer->data;
    lua_rawgetp(L, LUA_REGISTRYINDEX, timer);
    lua_getuservalue(L, -1);
    lua_remove(L, -2);

    safecall(L, "timer", 0, 0);
}

static int l_start(lua_State *L)
{
    uv_timer_t *timer = luaL_checkudata(L, 1, "uv_timer");
    lua_Integer millis = luaL_checkinteger(L, 2);
    luaL_checkany(L, 3);
    lua_settop(L, 3);
    lua_setuservalue(L, 1);
    int r = uv_timer_start(timer, on_timer, millis, millis);
    assert(0 == r);
    return 0;
}

static luaL_Reg MT[] = {
    {"close", l_close},
    {"start", l_start},
    {}
};

void push_new_uv_timer(lua_State *L, uv_loop_t *loop)
{
    uv_timer_t *timer = lua_newuserdata(L, sizeof *timer);
    timer->data = L;

    if (luaL_newmetatable(L, "uv_timer")) {
        luaL_setfuncs(L, MT, 0);
        lua_pushvalue(L, -1);
        lua_setfield(L, -2, "__index");
    }
    lua_setmetatable(L, -2);

    lua_pushvalue(L, -1);
    lua_rawsetp(L, LUA_REGISTRYINDEX, timer);

    int r = uv_timer_init(loop, timer);
    assert(0 == r);
}
