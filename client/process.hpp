#pragma once

struct lua_State;

auto l_execute(lua_State* L) -> int;
