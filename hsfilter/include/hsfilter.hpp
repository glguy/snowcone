#pragma once

struct lua_State;

auto luaopen_hsfilter(lua_State * L) -> int;
