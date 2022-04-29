#ifndef MY_SAFECALL_H
#define MY_SAFECALL_H

extern "C" {
#include "lua.h"
}

int safecall(lua_State *L, char const* location, int args);

#endif