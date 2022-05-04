#pragma once

extern "C" {
#include "lua.h"
}

#include <uv.h>

void push_new_uv_timer(lua_State *L, uv_loop_t *);
