#include <assert.h>

#include "app.h"
#include "lua_uv_timer.h"
#include "lauxlib.h"
#include "safecall.h"

static char const* const typename = "uv_timer";

static void on_close(uv_handle_t *handle)
{
    struct app * const a = handle->loop->data;
    lua_State * const L = a->L;
    lua_pushnil(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, handle);
}

static int l_close(lua_State *L)
{
    uv_timer_t *timer = luaL_checkudata(L, 1, typename);
    uv_close((uv_handle_t*)timer, on_close);
    return 0;
}

static void on_timer(uv_timer_t *timer)
{
    struct app * const a = timer->loop->data;
    lua_State * const L = a->L;
    lua_rawgetp(L, LUA_REGISTRYINDEX, timer);
    lua_getuservalue(L, -1);
    lua_remove(L, -2);

    safecall(L, "timer", 0);
}

static int l_start(lua_State *L)
{
    uv_timer_t *timer = luaL_checkudata(L, 1, typename);
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

    if (luaL_newmetatable(L, typename)) {
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
