#pragma once

struct lua_State;

auto luaopen_myopenssl(lua_State * const L) -> int;
