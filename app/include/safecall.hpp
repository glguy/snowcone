#pragma once

extern "C" {
#include "lua.h"
}

int safecall(lua_State* L, char const* location, int args);
