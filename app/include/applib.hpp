#pragma once

#include "app.hpp"

#include <ircmsg.hpp>

extern "C" {
#include "lualib.h"
}

void load_logic(lua_State* L, char const* filename);
void lua_callback(lua_State* L, char const* key);
void pushircmsg(lua_State* L, ircmsg const& msg);
void prepare_globals(lua_State* L, configuration* cfg);
