#pragma once

struct lua_State;

namespace myopenssl {

/// @brief Throw Lua error for an OpenSSL library failure
/// @param L Lua interpreter state
/// @param func Name of failed function
[[noreturn]]
auto openssl_failure(lua_State* L, char const* func) -> void;

} // namespace myopenssl
