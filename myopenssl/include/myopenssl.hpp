#pragma once

// Entry point of the myopenssl Lua module.

struct lua_State;

/// Lua module opener: pushes the myopenssl library table. Also installs
/// a null default UI method in OpenSSL, process-wide, so nothing prompts
/// on the terminal.
extern "C" auto luaopen_myopenssl(lua_State* const L) -> int;
