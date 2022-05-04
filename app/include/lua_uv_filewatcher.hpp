#pragma once

extern "C" {
#include "lua.h"
}

#include <uv.h>

void push_new_fs_event(lua_State *L, uv_loop_t *loop);
