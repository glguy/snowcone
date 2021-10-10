#ifndef MY_UV_TIMER_H
#define MY_UV_TIMER_H

#include <lua.h>
#include <uv.h>

void push_new_uv_timer(lua_State *L, uv_loop_t *);

#endif