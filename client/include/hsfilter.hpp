#pragma once

#include "config.hpp"

#ifdef LIBHS_FOUND

struct lua_State;

auto luaopen_hsfilter(lua_State * L) -> int;

#endif