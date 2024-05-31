#pragma once

struct lua_State;

extern "C" auto luaopen_mytoml(lua_State*) -> int;
