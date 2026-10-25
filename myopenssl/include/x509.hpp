#pragma once

#include <openssl/x509.h>

struct lua_State;

namespace myopenssl {
auto l_new_x509(lua_State*) -> int;
auto l_read_x509(lua_State*) -> int;
auto check_x509(lua_State* const L, int const arg) -> X509*;
/// The certificate at arg, or null if it isn't one or is closed. Never raises.
auto test_x509(lua_State* L, int arg) -> X509*;
}
