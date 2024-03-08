#pragma once

struct lua_State;

extern "C" auto luaopen_myopenssl(lua_State * const L) -> int;
