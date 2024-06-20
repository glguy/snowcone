#pragma once

extern "C" {
struct lua_State;
int start_httpd(lua_State*);
}
