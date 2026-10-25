#pragma once

struct lua_State;
struct luaL_Reg;

namespace myopenssl {

/// @brief Throw Lua error for an OpenSSL library failure
/// @param L Lua interpreter state
/// @param func Name of failed function
[[noreturn]]
auto openssl_failure(lua_State* L, char const* func) -> void;

/// @brief Throw Lua error with the given message, followed by any queued
/// OpenSSL errors
/// @param L Lua interpreter state
/// @param message First line of the error
[[noreturn]]
auto openssl_failure_message(lua_State* L, char const* message) -> void;

/// @brief Like luaL_setfuncs with no upvalues, but each function runs
/// behind a boundary: the OpenSSL error queue is cleared first, so errors
/// it reports are its own, and an escaping C++ exception becomes a Lua error.
///
/// __gc and __close are registered directly. A collection can run during
/// any allocation, including while openssl_failure builds its message, and
/// clearing the queue there would lose the errors being reported.
///
/// @param L Lua interpreter state, with the target table on top
/// @param regs Null-terminated function list with static storage duration
auto setfuncs(lua_State* L, luaL_Reg const* regs) -> void;

} // namespace myopenssl
